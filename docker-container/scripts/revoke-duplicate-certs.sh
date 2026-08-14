#!/bin/bash
#
# TAK Server Certificate Cleanup Script
# 
# Phase 1: Revoke superseded certificates (keeps newest per user+device)
# Phase 2: Delete old revoked certificates (revoked > X days ago)
#
# Phase 1 sources from /certadmin/cert/replaced rather than
# /certadmin/cert/active. TAK Server's /certadmin/cert/active endpoint
# (TakCertRepository.getActive()) already returns at most one row per
# (userDn, clientUid) pair -- the newest by issuanceDate -- so a client-side
# "find duplicates within active" pass can never find anything: the
# precondition it's checking for is structurally impossible in that
# endpoint's response. TAK Server calls every older cert for the same key
# "replaced" instead, and exposes those via /certadmin/cert/replaced
# (TakCertRepository.getReplaced()). "Replaced" is a purely cosmetic
# label for the admin UI though -- X509Authenticator.auth() only checks
# revocationDate at authentication time, so a replaced-but-not-revoked cert
# authenticates exactly like an active one. Revoking every row returned by
# /replaced is what actually retires the old cert.
#
# Uses efficient O(N) algorithms and parallel processing

set -eo pipefail

# Configuration
ADMIN_CERT="/opt/tak/certs/files/admin.pem"
ADMIN_KEY="/opt/tak/certs/files/admin.key"
ADMIN_PASS="atakatak"
API_BASE="https://localhost:8443"
CURL_TIMEOUT=10
MAX_PARALLEL_JOBS=5
# Note: Only deletes revoked certs that have also expired (prevents unrevocation)

# Check bash version
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    echo "Warning: Bash 4.3+ required for parallel processing. Falling back to sequential mode."
    PARALLEL_MODE=false
else
    PARALLEL_MODE=true
fi

echo "========================================"
echo "TAK Server Certificate Cleanup"
echo "========================================"
echo ""

# ============================================================================
# PHASE 1: Revoke Superseded Certificates
# ============================================================================
echo "PHASE 1: Revoking superseded certificates"
echo "------------------------------------------"

echo "Fetching replaced (superseded) certificates..."
REPLACED_JSON=$(curl -ks \
  --cert "$ADMIN_CERT" \
  --key "$ADMIN_KEY" \
  --pass "$ADMIN_PASS" \
  --max-time "$CURL_TIMEOUT" \
  "$API_BASE/Marti/api/certadmin/cert/replaced" 2>/dev/null)

if [ -z "$REPLACED_JSON" ]; then
    echo "Error: Failed to fetch replaced certificates"
    exit 1
fi

# TAK Server's getReplaced() already returns exactly the set of certs that
# have been superseded by a newer enrollment for the same (userDn,
# clientUid) -- no client-side dedup math is needed here. We only filter
# out ones that are already revoked (revocationDate != null), so re-running
# this script is a no-op for certs it already handled.
declare -a superseded_to_revoke
total_replaced_certs=0

while IFS='|' read -r id revocation_date; do
    [ -z "$id" ] || [ "$id" = "null" ] && continue
    total_replaced_certs=$((total_replaced_certs + 1))
    superseded_to_revoke+=("$id")
done < <(echo "$REPLACED_JSON" | jq -r '.data[] | select(.id != null and .revocationDate == null) | "\(.id)|\(.revocationDate)"')

echo "Found $total_replaced_certs replaced certificate(s) not yet revoked"

if [ ${#superseded_to_revoke[@]} -eq 0 ]; then
    echo "No superseded certificates found."
else
    echo "Found ${#superseded_to_revoke[@]} superseded certificates to revoke"
    
    revoke_cert() {
        local id="$1"
        local http_code
        http_code=$(curl -ks \
          --cert "$ADMIN_CERT" \
          --key "$ADMIN_KEY" \
          --pass "$ADMIN_PASS" \
          --max-time "$CURL_TIMEOUT" \
          -w "%{http_code}" \
          -o /dev/null \
          -X DELETE \
          "$API_BASE/Marti/api/certadmin/cert/revoke/$id" 2>/dev/null)
        
        [ "$http_code" = "200" ] && echo "  ✓ Revoked ID: $id" || echo "  ✗ Failed ID: $id (HTTP $http_code)"
    }
    
    if [ "$PARALLEL_MODE" = true ]; then
        for id in "${superseded_to_revoke[@]}"; do
            while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]; do
                wait -n 2>/dev/null || true
            done
            revoke_cert "$id" &
        done
        wait
    else
        for id in "${superseded_to_revoke[@]}"; do
            revoke_cert "$id"
        done
    fi
fi

echo ""

# ============================================================================
# PHASE 2: Delete Expired Revoked Certificates
# ============================================================================
echo "PHASE 2: Deleting expired revoked certificates"
echo "----------------------------------------"

echo "Fetching revoked certificates..."
REVOKED_JSON=$(curl -ks \
  --cert "$ADMIN_CERT" \
  --key "$ADMIN_KEY" \
  --pass "$ADMIN_PASS" \
  --max-time "$CURL_TIMEOUT" \
  "$API_BASE/Marti/api/certadmin/cert/revoked" 2>/dev/null)

if [ -z "$REVOKED_JSON" ]; then
    echo "Error: Failed to fetch revoked certificates"
    exit 1
fi

# Current date for expiration comparison
CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%S")
echo "Deleting certificates that are revoked AND expired (expiration < $CURRENT_DATE)"

# Find expired revoked certificates
declare -a expired_revoked_ids
while IFS='|' read -r id expiration_date; do
    [ -z "$id" ] || [ "$id" = "null" ] || [ -z "$expiration_date" ] || [ "$expiration_date" = "null" ] && continue
    [[ "$expiration_date" < "$CURRENT_DATE" ]] && expired_revoked_ids+=("$id")
done < <(echo "$REVOKED_JSON" | jq -r '.data[] | select(.id != null and .expirationDate != null) | "\(.id)|\(.expirationDate)"')

if [ ${#expired_revoked_ids[@]} -eq 0 ]; then
    echo "No expired revoked certificates to delete."
else
    echo "Found ${#expired_revoked_ids[@]} expired revoked certificates to delete"
    
    delete_cert() {
        local id="$1"
        local http_code
        http_code=$(curl -ks \
          --cert "$ADMIN_CERT" \
          --key "$ADMIN_KEY" \
          --pass "$ADMIN_PASS" \
          --max-time "$CURL_TIMEOUT" \
          -w "%{http_code}" \
          -o /dev/null \
          -X DELETE \
          "$API_BASE/Marti/api/certadmin/cert/delete/$id" 2>/dev/null)
        
        [ "$http_code" = "200" ] && echo "  ✓ Deleted ID: $id" || echo "  ✗ Failed ID: $id (HTTP $http_code)"
    }
    
    if [ "$PARALLEL_MODE" = true ]; then
        for id in "${expired_revoked_ids[@]}"; do
            while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]; do
                wait -n 2>/dev/null || true
            done
            delete_cert "$id" &
        done
        wait
    else
        for id in "${expired_revoked_ids[@]}"; do
            delete_cert "$id"
        done
    fi
fi

echo ""
echo "========================================"
echo "Certificate cleanup complete"
echo "========================================"
echo "Phase 1: Revoked ${#superseded_to_revoke[@]} superseded certificates"
echo "Phase 2: Deleted ${#expired_revoked_ids[@]} expired revoked certificates"
echo ""
