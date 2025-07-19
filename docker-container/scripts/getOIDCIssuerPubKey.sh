#!/bin/bash

# Define the JWKS URL from the TAK Server configuration
jwks_url="${TAKSERVER_CoreConfig_OAuthServer_JWKS}"

# Fetch the JWKS data
jwks_data=$(curl -s -f "$jwks_url")

# Check if curl was successful
if [ $? -ne 0 ]; then
    echo "warning - TAK Server - Failed to download OIDC issuer public certificate from $jwks_url"
    echo "" > "${TAKSERVER_CoreConfig_OAuthServer_Issuer}"
    exit 0
fi

# Extract the x5c value
x5c_value=$(echo "$jwks_data" | jq -r '.keys[0].x5c[0]')

# Check if jq extraction was successful
if [ -z "$x5c_value" ] || [ "$x5c_value" == "null" ]; then
    echo "warning - TAK Server - Failed to extract x5c value from JWKS data"
    echo "" > "${TAKSERVER_CoreConfig_OAuthServer_Issuer}"
    exit 0
fi

# Format the certificate
formatted_cert="-----BEGIN CERTIFICATE-----
$x5c_value
-----END CERTIFICATE-----"

# Convert the certificate for use with TAK Server
echo "ok - TAK Server - Downloading OIDC issuer public certificate from $jwks_url"
echo "$formatted_cert" | openssl x509 -pubkey -noout > "${TAKSERVER_CoreConfig_OAuthServer_Issuer}" || {
    echo "warning - TAK Server - Failed to convert certificate"
    echo "" > "${TAKSERVER_CoreConfig_OAuthServer_Issuer}"
}




