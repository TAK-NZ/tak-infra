#!/bin/bash

# TAK Server Certificate Expiration Checker
# 
# This script identifies certificates expiring within the next month and checks
# if their associated users have been active in the last 30 days. It queries
# the TAK Server API to retrieve certificate data and client endpoint activity,
# then cross-references them to help administrators identify which expiring
# certificates belong to active vs inactive users.

set -euo pipefail

CERT_PATH="/opt/tak/certs/files/admin.pem"
KEY_PATH="/opt/tak/certs/files/admin.key"
KEY_PASS="atakatak"
BASE_URL="https://localhost:8443/Marti/api"

# Calculate dates
ONE_MONTH_FROM_NOW=$(date -d "+1 month" -u +"%Y-%m-%dT%H:%M:%S.000Z")
THIRTY_DAYS_AGO=$(date -d "-30 days" -u +"%Y-%m-%dT%H:%M:%S.000Z")

echo "Checking for certificates expiring before: $ONE_MONTH_FROM_NOW"
echo "Checking for user activity since: $THIRTY_DAYS_AGO"
echo

# Fetch certificates
CERTS=$(curl -s -k --cert "$CERT_PATH" --key "$KEY_PATH" --pass "$KEY_PASS" "$BASE_URL/certadmin/cert")
if [[ -z "$CERTS" ]]; then
    echo "Error: No response from cert API"
    exit 1
fi

# Fetch client endpoints
ENDPOINTS=$(curl -s -k --cert "$CERT_PATH" --key "$KEY_PATH" --pass "$KEY_PASS" "$BASE_URL/clientEndPoints")
if [[ -z "$ENDPOINTS" ]]; then
    echo "Error: No response from endpoints API"
    exit 1
fi

# Find expiring certificates
EXPIRING_CERTS=$(echo "$CERTS" | jq --arg cutoff "$ONE_MONTH_FROM_NOW" '
    .data[] | 
    select(.revocationDate == null and .expirationDate < $cutoff) |
    {userDn, clientUid, expirationDate, hash}
')

if [[ -z "$EXPIRING_CERTS" ]]; then
    echo "No certificates expiring in the next month"
    exit 0
fi

echo "Found certificates expiring in the next month:"
echo

# Process each expiring certificate
echo "$EXPIRING_CERTS" | jq -c '.' | while read -r cert; do
    USER_DN=$(echo "$cert" | jq -r '.userDn')
    CLIENT_UID=$(echo "$cert" | jq -r '.clientUid')
    EXPIRATION=$(echo "$cert" | jq -r '.expirationDate')
    HASH=$(echo "$cert" | jq -r '.hash')
    
    echo "Certificate: $USER_DN ($CLIENT_UID)"
    echo "  Expires: $EXPIRATION"
    echo "  Hash: $HASH"
    
    # Check if user has been active in last 30 days
    RECENT_ACTIVITY=$(echo "$ENDPOINTS" | jq --arg username "$USER_DN" --arg cutoff "$THIRTY_DAYS_AGO" '
        .[] | select(.username == $username and .lastEventTime > $cutoff)
    ')
    
    if [[ -n "$RECENT_ACTIVITY" ]]; then
        LAST_SEEN=$(echo "$RECENT_ACTIVITY" | jq -r '.lastEventTime')
        CALLSIGN=$(echo "$RECENT_ACTIVITY" | jq -r '.callsign')
        echo "  ✓ User active - Last seen: $LAST_SEEN (Callsign: $CALLSIGN)"
    else
        echo "  ⚠ User inactive - No activity in last 30 days"
    fi
    echo
done