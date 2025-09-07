#!/bin/bash

# TAK Server Duplicate Certificate Cleanup
# 
# This script identifies and revokes duplicate certificates for the same user/device
# combination. It keeps the most recently issued certificate and revokes all older
# duplicates to prevent authentication conflicts and maintain certificate hygiene.

set -euo pipefail

CERT_PATH="/opt/tak/certs/files/admin.pem"
KEY_PATH="/opt/tak/certs/files/admin.key"
KEY_PASS="atakatak"
BASE_URL="https://localhost:8443/Marti/api/certadmin"

echo "Fetching all certificates from TAK Server..."

CERTS=$(curl -s -k --cert "$CERT_PATH" --key "$KEY_PATH" --pass "$KEY_PASS" "$BASE_URL/cert")

if [[ -z "$CERTS" ]]; then
    echo "Error: No response from server"
    exit 1
fi

echo "Processing certificates to find duplicates..."

TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Extract certificates from .data array and filter non-revoked ones
echo "$CERTS" | jq -r '.data[] | select(.revocationDate == null) | "\(.userDn)|\(.clientUid)|\(.issuanceDate)|\(.hash)"' | sort > "$TEMP_FILE"

echo "Found $(wc -l < "$TEMP_FILE") active certificates"

# Process duplicates
processed_keys=()
while IFS='|' read -r user_dn client_uid issuance_date hash; do
    key="${user_dn}|${client_uid}"
    
    # Skip if already processed
    if [[ " ${processed_keys[*]} " =~ " ${key} " ]]; then
        continue
    fi
    
    # Get all certificates for this combination
    matching_certs=$(grep "^${user_dn}|${client_uid}|" "$TEMP_FILE")
    cert_count=$(echo "$matching_certs" | wc -l)
    
    if [[ $cert_count -gt 1 ]]; then
        echo "Found $cert_count certificates for userDn='$user_dn', clientUid='$client_uid'"
        
        # Get hashes to revoke (all except the most recent)
        hashes_to_revoke=$(echo "$matching_certs" | sort -t'|' -k3 -r | tail -n +2 | cut -d'|' -f4)
        
        for hash_to_revoke in $hashes_to_revoke; do
            echo "  Revoking certificate: $hash_to_revoke"
            
            if curl -s -k -X DELETE --cert "$CERT_PATH" --key "$KEY_PATH" --pass "$KEY_PASS" "$BASE_URL/cert/$hash_to_revoke" >/dev/null; then
                echo "    ✓ Revoked $hash_to_revoke"
            else
                echo "    ✗ Failed to revoke $hash_to_revoke"
            fi
        done
    fi
    
    processed_keys+=("$key")
done < "$TEMP_FILE"

echo "Certificate cleanup completed."