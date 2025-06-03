#!/bin/bash

# Define the JWKS URL from the TAK Server configuration
jwks_url="${TAKSERVER_CoreConfig_OAuthServer_JWKS}"

# Fetch the JWKS data
jwks_data=$(curl -s "$jwks_url")

# Extract the x5c value
x5c_value=$(echo "$jwks_data" | jq -r '.keys[0].x5c[0]')

# Format the certificate
formatted_cert="-----BEGIN CERTIFICATE-----
$x5c_value
-----END CERTIFICATE-----"

# Convert the certificate for use with TAK Server
echo "ok - TAK Server - Downloading OIDC issuer public certificate from $jwks_url"
echo "$formatted_cert" | openssl x509 -pubkey -noout  > ${TAKSERVER_CoreConfig_OAuthServer_Issuer}




