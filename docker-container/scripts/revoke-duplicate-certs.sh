#!/bin/bash
#
# TAK Server Certificate Cleanup Script
# 
# Phase 1: Revoke duplicate certificates (keeps newest per user+device)
# Phase 2: Delete old revoked certificates (revoked > X days ago)
#
# Uses efficient O(N) algorithms and parallel processing

set -euo pipefail

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
# PHASE 1: Revoke Duplicate Certificates
# ============================================================================
echo "PHASE 1: Revoking duplicate certificates"
echo "----------------------------------------"

echo "Fetching active certificates..."
ACTIVE_JSON=$(curl -ks \
  --cert "$ADMIN_CERT" \
  --key "$ADMIN_KEY" \
  --pass "$ADMIN_PASS" \
  --max-time "$CURL_TIMEOUT" \
  "$API_BASE/Marti/api/certadmin/cert/active" 2>/dev/null)

if [ -z "$ACTIVE_JSON" ]; then
    echo "Error: Failed to fetch active certificates"
    exit 1
fi

# Build user+device map to find duplicates
declare -A user_device_newest_date
declare -A user_device_newest_id
declare -a all_active_certs

while IFS='|' read -r id user_dn client_uid issuance_date; do
    [ -z "$id" ] || [ "$id" = "null" ] && continue
    
    # Create unique key from user + device
    user_device_key="${user_dn}|${client_uid}"
    all_active_certs+=("$id|$user_device_key|$issuance_date")
    
    if [ -z "${user_device_newest_date[$user_device_key]:-}" ] || [[ "$issuance_date" > "${user_device_newest_date[$user_device_key]}" ]]; then
        user_device_newest_date[$user_device_key]="$issuance_date"
        user_device_newest_id[$user_device_key]="$id"
    fi
done < <(echo "$ACTIVE_JSON" | jq -r '.data[] | select(.id != null and .userDn != null and .clientUid != null and .issuanceDate != null and .revocationDate == null) | "\(.id)|\(.userDn)|\(.clientUid)|\(.issuanceDate)"')

echo "Found ${#all_active_certs[@]} active certificates"
echo "Found ${#user_device_newest_id[@]} unique user+device combinations"

# Identify duplicates
declare -a duplicates_to_revoke
for cert_info in "${all_active_certs[@]}"; do
    IFS='|' read -r id user_device_key issuance_date <<< "$cert_info"
    [ "$id" != "${user_device_newest_id[$user_device_key]}" ] && duplicates_to_revoke+=("$id")
done

if [ ${#duplicates_to_revoke[@]} -eq 0 ]; then
    echo "No duplicate certificates found."
else
    echo "Found ${#duplicates_to_revoke[@]} duplicates to revoke"
    
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
        for id in "${duplicates_to_revoke[@]}"; do
            while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]; do
                wait -n 2>/dev/null || true
            done
            revoke_cert "$id" &
        done
        wait
    else
        for id in "${duplicates_to_revoke[@]}"; do
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
echo "Phase 1: Revoked ${#duplicates_to_revoke[@]} duplicate certificates"
echo "Phase 2: Deleted ${#expired_revoked_ids[@]} expired revoked certificates"
echo ""
