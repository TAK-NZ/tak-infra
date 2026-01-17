#!/bin/bash

# TAK Server Duplicate Certificate Cleanup (Optimized)
# 
# This script identifies and revokes duplicate certificates for the same user/device
# combination. It keeps the most recently issued certificate and revokes all older
# duplicates to prevent authentication conflicts and maintain certificate hygiene.
#
# Improvements:
# 1. Complexity reduced from O(N²) to O(N) using sort + single pass
# 2. Eliminates repetitive grep scans inside loops
# 3. Parallelizes network calls for faster cleanup

set -euo pipefail

# Check bash version for wait -n support (requires 4.3+)
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    echo "Warning: Bash 4.3+ required for parallel processing. Falling back to sequential mode."
    PARALLEL_MODE=false
else
    PARALLEL_MODE=true
fi

# --- Configuration ---
CERT_PATH="/opt/tak/certs/files/admin.pem"
KEY_PATH="/opt/tak/certs/files/admin.key"
KEY_PASS="atakatak"
BASE_URL="https://localhost:8443/Marti/api/certadmin"
MAX_CONCURRENT_JOBS=5
CURL_TIMEOUT=10

# Ensure dependencies exist
command -v jq >/dev/null 2>&1 || { echo >&2 "Error: jq is required but not installed."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "Error: curl is required but not installed."; exit 1; }

echo "[$(date)] Starting Certificate Cleanup..."
echo "Fetching certificate list from TAK Server..."

CERTS=$(curl -s -k --max-time "$CURL_TIMEOUT" --cert "$CERT_PATH" --key "$KEY_PATH" --pass "$KEY_PASS" "$BASE_URL/cert")

if [[ -z "$CERTS" ]]; then
    echo "Error: Empty response from server. Check connection or credentials."
    exit 1
fi

# Create a safe temp file
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Parse and Sort
# Logic:
# - Filter for non-revoked certs
# - Output format: "UserDN | ClientUID | IssuanceDate | Hash"
# - Sort keys (-k1,2): Group by UserDN + ClientUID
# - Sort date (-k3r): Reverse sort date (Newest First)
# Result: The first line for any user is the NEWEST cert. All following lines are OLDER.
echo "Parsing and sorting certificates..."
echo "$CERTS" | jq -r '.data[] | select(.revocationDate == null) | "\(.userDn)|\(.clientUid)|\(.issuanceDate)|\(.hash)"' \
    | sort -t'|' -k1,2 -k3r > "$TEMP_FILE"

TOTAL_CERTS=$(wc -l < "$TEMP_FILE")
echo "Found $TOTAL_CERTS active certificates. Checking for duplicates..."

# Iterate and Revoke
prev_key=""
revocation_count=0

while IFS='|' read -r user_dn client_uid issuance_date hash; do
    # Create a unique key for the User+Device combination
    current_key="${user_dn}|${client_uid}"

    if [[ "$current_key" == "$prev_key" ]]; then
        # DUPLICATE FOUND - This is an older certificate, revoke it
        echo "  [Revoking] Duplicate for $user_dn ($client_uid) - Hash: $hash"
        
        if [[ "$PARALLEL_MODE" == true ]]; then
            # Run curl in background
            (
                if curl -s -k --max-time "$CURL_TIMEOUT" -X DELETE --cert "$CERT_PATH" --key "$KEY_PATH" --pass "$KEY_PASS" "$BASE_URL/cert/$hash" >/dev/null; then
                    echo "    -> Success: $hash"
                else
                    echo "    -> Failed: $hash" >&2
                fi
            ) &
            
            # Job Control: Limit concurrency
            if [[ $(jobs -r -p | wc -l) -ge $MAX_CONCURRENT_JOBS ]]; then
                wait -n
            fi
        else
            # Sequential mode
            if curl -s -k --max-time "$CURL_TIMEOUT" -X DELETE --cert "$CERT_PATH" --key "$KEY_PATH" --pass "$KEY_PASS" "$BASE_URL/cert/$hash" >/dev/null; then
                echo "    -> Success: $hash"
            else
                echo "    -> Failed: $hash"
            fi
        fi
        
        revocation_count=$((revocation_count + 1))
    else
        # NEWEST CERTIFICATE - Keep it
        prev_key="$current_key"
    fi
done < "$TEMP_FILE"

# Wait for any remaining background jobs
if [[ "$PARALLEL_MODE" == true ]]; then
    wait
fi

echo "[$(date)] Cleanup Completed. Revoked $revocation_count duplicates."