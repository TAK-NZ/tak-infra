#!/bin/bash
#
# Build CoreConfig & Associated Cert Generation
#

set -euo pipefail

# Signal handler for graceful shutdown
cleanup_and_exit() {
    echo "TAK Server - Received shutdown signal, cleaning up..."
    # Kill background processes gracefully
    [[ -n "${LETSENCRYPT_PID:-}" ]] && kill -TERM "$LETSENCRYPT_PID" 2>/dev/null || true
    [[ -n "${CRON_PID:-}" ]] && kill -TERM "$CRON_PID" 2>/dev/null || true
    [[ -n "${ADMIN_ELEVATION_PID:-}" ]] && kill -TERM "$ADMIN_ELEVATION_PID" 2>/dev/null || true
    # Since TAK server will be the main process, signals will be handled by it directly
    exit 0
}
trap 'cleanup_and_exit' SIGTERM SIGINT

# Validate required environment variables
validate_environment() {
    local missing_vars=()
    
    [[ -z "${StackName:-}" ]] && missing_vars+=("StackName")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "Error: Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
}

# Check command availability
check_commands() {
    local missing_commands=()
    
    for cmd in java openssl keytool aws; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        echo "Error: Missing required commands: ${missing_commands[*]}"
        exit 1
    fi
}

echo "TAK Server - New ECS Task starting..."

# Validate environment and commands
validate_environment
check_commands

# Ensure TAK certs Directory is present
if [ ! -d "/opt/tak/certs/files/" ]; then
    mkdir -p "/opt/tak/certs/files/"
fi

# Attempt to restore Certbot Cronjob
echo "Certbot - Restoring cronjob"
if [ ! -e "/etc/cron.d/certbot" ]; then
    cp /etc/letsencrypt/certbot.cron /etc/cron.d/certbot || true
fi

# Check if TAK certs exist, otherwise generate them
cd /opt/tak/certs
if [ ! -f "/opt/tak/certs/files/ca.pem" ]; then
    echo "TAK Server - Generating new certificates..."
    echo "TAK Server - CA Country: ${TAKSERVER_CACert_Country:-NZ}"
    echo "TAK Server - CA State: ${TAKSERVER_CACert_State:-Wellington}"
    echo "TAK Server - CA City: ${TAKSERVER_CACert_City:-Wellington}"
    echo "TAK Server - CA Organization: ${TAKSERVER_CACert_Org:-TAK.NZ}"
    echo "TAK Server - CA Organizational Unit: ${TAKSERVER_CACert_OrgUnit:-TAK.NZ Operations}" 
    export COUNTRY="${TAKSERVER_CACert_Country:-NZ}"
    export STATE="${TAKSERVER_CACert_State:-Wellington}"
    export CITY="${TAKSERVER_CACert_City:-Wellington}"
    export ORGANIZATION="${TAKSERVER_CACert_Org:-TAK.NZ}"
    export ORGANIZATIONAL_UNIT="${TAKSERVER_CACert_OrgUnit:-TAK.NZ Operations}"
    sed -i -e 's/COUNTRY=US/COUNTRY=${COUNTRY}/' /opt/tak/certs/cert-metadata.sh
    /opt/tak/certs/cert-metadata.sh
    mkdir -p "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain:-nodomainset}/"
    /opt/tak/certs/makeRootCa.sh --ca-name "${TAKSERVER_CACert_Org:-TAK.NZ}"
    { yes || :; } | /opt/tak/certs/makeCert.sh ca intermediate-ca
    { yes || :; } | /opt/tak/certs/makeCert.sh server takserver
    { yes || :; } | /opt/tak/certs/makeCert.sh client admin

    # Validate certificate generation
    if [[ ! -f "files/admin.p12" ]]; then
        echo "Error: Failed to generate admin certificate"
        exit 1
    fi
fi

# Upload certificates to AWS Secrets Manager using file hashes as client request tokens
# The client-request-token parameter ensures certificates are only uploaded if they were 
# changed or did not exist in AWS Secrets Manager
echo "TAK Server - Uploading certificates to AWS Secrets Manager"

# Upload admin certificate if it exists
if [ -f "/opt/tak/certs/files/admin.p12" ]; then
    # Generate SHA-256 hash of the admin certificate file as client request token
    ADMIN_CERT_HASH=$(sha256sum "/opt/tak/certs/files/admin.p12" | cut -d' ' -f1)
    
    # Store TAK admin certificate in AWS Secrets Manager for secure access
    if ! aws secretsmanager put-secret-value \
        --secret-id "${StackName}/TAK-Server/Admin-Cert" \
        --secret-binary fileb:///opt/tak/certs/files/admin.p12 \
        --client-request-token "${ADMIN_CERT_HASH}" 2>/tmp/aws_error.log; then
        # Check if error is due to duplicate client request token (no change needed)
        if grep -q "ClientRequestTokenConflictException" /tmp/aws_error.log; then
            echo "TAK Server - Admin certificate unchanged, skipping update"
        else
            echo "Warning: Failed to store admin certificate in Secrets Manager"
            echo "AWS CLI Error:"
            cat /tmp/aws_error.log
        fi
    else
        echo "TAK Server - Successfully updated admin certificate in Secrets Manager"
    fi
fi

# Upload CA certificate if it exists
if [ -f "/opt/tak/certs/files/ca.pem" ]; then
    # Generate SHA-256 hash of the CA certificate file as client request token
    CA_CERT_HASH=$(sha256sum "/opt/tak/certs/files/ca.pem" | cut -d' ' -f1)
    
    # Store CA certificate in AWS Secrets Manager as text
    if ! aws secretsmanager put-secret-value \
        --secret-id "${StackName}/TAK-Server/FederateCA" \
        --secret-string file:///opt/tak/certs/files/ca.pem \
        --client-request-token "${CA_CERT_HASH}" 2>/tmp/aws_error.log; then
        # Check if error is due to duplicate client request token (no change needed)
        if grep -q "ClientRequestTokenConflictException" /tmp/aws_error.log; then
            echo "TAK Server - CA certificate unchanged, skipping update"
        else
            echo "Warning: Failed to store CA certificate in Secrets Manager"
            echo "AWS CLI Error:"
            cat /tmp/aws_error.log
        fi
    else
        echo "TAK Server - Successfully updated CA certificate in Secrets Manager"
    fi
fi

# Restore certs for self-enrollment (HTTPS on TCP/8446)
# Check if certs for self-enrollment (HTTPS on TCP/8446) exist
mkdir -p "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain:-nodomainset}" || true
if [[ -f "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" && \
    -n "${TAKSERVER_QuickConnect_LetsEncrypt_Domain:-}" && \
    -n "${TAKSERVER_QuickConnect_LetsEncrypt_CertType:-}" && \
    ( "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "production" || "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "staging" ) \
    ]]; then
    # Previous LetsEncrypt cert exists, convert it to JKS format
    echo "TAK Server - Converting LetsEncrypt certs to TAK format"
    
    # Validate required certificate files exist
    if [[ ! -f "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/privkey.pem" ]]; then
        echo "Warning: LetsEncrypt private key not found, using self-signed certificates"
        cp "/opt/tak/certs/files/takserver.jks" "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks" || true
    else
    
    # Display certificate information for verification
    openssl x509 \
        -text \
        -in "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" \
        -noout

    # Convert LetsEncrypt PEM certificates to PKCS12 format
    openssl pkcs12 \
        -export \
        -in "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" \
        -inkey "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/privkey.pem" \
        -out "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.p12" \
        -name "${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" \
        -password "pass:atakatak"

    # Remove existing JKS file to prevent keytool from appending
    rm -f "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks"
    
        # Convert PKCS12 keystore to JKS format for TAK Server
        if ! { yes || :; } | keytool \
            -importkeystore \
            -srcstorepass "atakatak" \
            -deststorepass "atakatak" \
            -destkeystore "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks" \
            -srckeystore "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.p12" \
            -srcstoretype "pkcs12"; then
            echo "Warning: Failed to convert LetsEncrypt certificate to JKS format, using self-signed certificates"
            cp "/opt/tak/certs/files/takserver.jks" "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks" || true
        fi
    fi
else 
    # No previous LetsEncrypt cert exists or settings call for none to be used, use the self-signed one instead
    echo "TAK Server - Using self-signed certs instead of LetsEncrypt certs"
    cp "/opt/tak/certs/files/takserver.jks" "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain:-nodomainset}/letsencrypt.jks" || true
fi


# Request LetsEncrypt certs in background (with small delay to avoid race conditions)
(
    sleep 5
    /opt/tak/scripts/letsencrypt-request-cert.sh
) &
LETSENCRYPT_PID=$!

# Download OIDC issuer public certificate if configured
if [ -n "${TAKSERVER_CoreConfig_OAuthServer_JWKS:-}" ] && [ -n "${TAKSERVER_CoreConfig_OAuthServer_Issuer:-}" ]; then
    echo "TAK Server - Downloading OIDC issuer public certificate"
    /opt/tak/scripts/getOIDCIssuerPubKey.sh
else
    echo "TAK Server - No OIDC issuer public certificate configured, skipping download"
fi


echo "TAK Server - Generating config file"
cd /opt/tak

# Ensure persistent config directory exists
mkdir -p /opt/tak/persistent-config

# Ensure persistent retention config directory exists
mkdir -p /opt/tak/persistent-config/retention

# Remove existing retention directory/symlink if it exists
if [ -e "/opt/tak/conf/retention" ]; then
    rm -rf /opt/tak/conf/retention
fi

# Create symlink for retention directory
ln -sf /opt/tak/persistent-config/retention /opt/tak/conf/retention

# Check if a persistent config file already exists
if [ -f "/opt/tak/persistent-config/CoreConfig.xml" ]; then
    echo "TAK Server - Found existing persistent configuration, will merge with environment settings"
else
    echo "TAK Server - No existing configuration found, creating new one"
fi

# Generate CoreConfig.xml in the persistent directory with merging
if ! /opt/tak/scripts/createCoreConfig.sh /opt/tak/persistent-config/CoreConfig.xml; then
    echo "Error: Failed to generate CoreConfig.xml"
    exit 1
fi

# Create symbolic link to the persistent config file
if [ -f "/opt/tak/CoreConfig.xml" ] && [ ! -L "/opt/tak/CoreConfig.xml" ]; then
    # Backup any existing file before replacing with symlink
    mv /opt/tak/CoreConfig.xml /opt/tak/CoreConfig.xml.bak
fi

# Create or update the symbolic link
ln -sf /opt/tak/persistent-config/CoreConfig.xml /opt/tak/CoreConfig.xml

echo "TAK Server - Validating config file"
if ! /opt/tak/validateConfig.sh /opt/tak/CoreConfig.xml; then
    echo "Error: CoreConfig.xml validation failed"
    exit 1
fi



# Database operations with retry logic
echo "TAK Server - Validate DB schema"
for i in {1..5}; do
    if java -jar /opt/tak/db-utils/SchemaManager.jar validate; then
        echo "TAK Server - Database schema validation successful"
        break
    fi
    if [ $i -eq 5 ]; then
        echo "Error: Database schema validation failed after 5 attempts"
        exit 1
    fi
    echo "TAK Server - Database validation attempt $i/5 failed, retrying in 10 seconds..."
    sleep 10
done

echo "TAK Server - Upgrading DB schema"
for i in {1..3}; do
    if java -jar /opt/tak/db-utils/SchemaManager.jar upgrade; then
        echo "TAK Server - Database schema upgrade successful"
        break
    fi
    if [ $i -eq 3 ]; then
        echo "Error: Database schema upgrade failed after 3 attempts"
        exit 1
    fi
    echo "TAK Server - Database upgrade attempt $i/3 failed, retrying in 15 seconds..."
    sleep 15
done

echo "TAK Server - Starting server"

# Setup certificate cleanup cron job
echo "TAK Server - Setting up certificate cleanup cron job"
cat > /etc/cron.d/tak-cert-cleanup << 'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Clean up duplicate certificates every 15 minutes
*/15 * * * * root /opt/tak/scripts/revoke-duplicate-certs.sh >> /var/log/tak-cert-cleanup.log 2>&1
EOF

# Start cron in background
echo "Certbot - Starting cron for certbot renewals"
/usr/sbin/cron &
CRON_PID=$!

# Start admin user elevation in background with timeout
(
    sleep 10
    echo "TAK Server - Starting to elevate admin user privileges..."
    SetAdminCommand="java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem"
    
    # Retry for maximum 10 minutes (60 attempts * 10 seconds)
    for i in {1..60}; do
        if $SetAdminCommand; then
            echo "TAK Server - Elevating admin user privileges succeeded after $((i * 10)) seconds"
            exit 0
        fi
        
        if [ $i -eq 60 ]; then
            echo "Warning: Failed to elevate admin user privileges after 10 minutes, continuing anyway..."
            exit 0
        fi
        
        echo "TAK Server - Elevating admin user privileges failed, retrying in 10 seconds... ($i/60)"
        sleep 10
    done
) &
ADMIN_ELEVATION_PID=$!

# Store PID for monitoring
echo $ADMIN_ELEVATION_PID > /tmp/admin_elevation.pid

echo "TAK Server - New ECS Task successfully started"

# Run TAK server as main process (not in background)
echo "TAK Server - Starting main TAK server process..."
exec /opt/tak/configureInDocker.sh init
