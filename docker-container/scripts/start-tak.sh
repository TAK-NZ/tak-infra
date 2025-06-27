#!/bin/bash
#
# Build CoreConfig & Associated Cert Generation
#

. $NVM_DIR/nvm.sh

set -euo pipefail

# Signal handler for graceful shutdown
cleanup_and_exit() {
    echo "TAK Server - Received shutdown signal, cleaning up..."
    # Kill background processes gracefully
    [[ -n "${LETSENCRYPT_PID:-}" ]] && kill -TERM "$LETSENCRYPT_PID" 2>/dev/null || true
    [[ -n "${CRON_PID:-}" ]] && kill -TERM "$CRON_PID" 2>/dev/null || true
    # Since TAK server will be the main process, signals will be handled by it directly
    exit 0
}
trap 'cleanup_and_exit' SIGTERM SIGINT

echo "TAK Server - New ECS Task starting..."

# Ensure TAK certs Directory is present
if [ -d "/opt/tak/certs/files/" ]; then
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
    echo "TAK Server - CA Country: ${TAKSERVER_CACert_Country:=NZ}"
    echo "TAK Server - CA State: ${TAKSERVER_CACert_State:=Wellington}"
    echo "TAK Server - CA City: ${TAKSERVER_CACert_City:=Wellington}"
    echo "TAK Server - CA Organization: ${TAKSERVER_CACert_Org:=TAK.NZ}"
    echo "TAK Server - CA Organizational Unit: ${TAKSERVER_CACert_OrgUnit:=TAK.NZ Operations}" 
    export COUNTRY=${TAKSERVER_CACert_Country}
    export STATE=${TAKSERVER_CACert_State}
    export CITY=${TAKSERVER_CACert_City}
    export ORGANIZATION=${TAKSERVER_CACert_Org}
    export ORGANIZATIONAL_UNIT=${TAKSERVER_CACert_OrgUnit}
    sed -i -e 's/COUNTRY=US/COUNTRY=${COUNTRY}/' /opt/tak/certs/cert-metadata.sh
    /opt/tak/certs/cert-metadata.sh
    mkdir -p "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain:=nodomainset}/"
    /opt/tak/certs/makeRootCa.sh --ca-name ${TAKSERVER_CACert_Org}
    { yes || :; } | /opt/tak/certs/makeCert.sh ca intermediate-ca
    { yes || :; } | /opt/tak/certs/makeCert.sh server takserver
    { yes || :; } | /opt/tak/certs/makeCert.sh client admin

    aws secretsmanager put-secret-value \
        --secret-id ${StackName}/TAK-Server/Admin-Cert \
        --secret-binary fileb://files/admin.p12 || true
fi

# Restore certs for self-enrollment (HTTPS on TCP/8446)
# Check if certs for self-enrollment (HTTPS on TCP/8446) exist
mkdir /opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain} || true
if [[ -d "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" && \
    ( "${TAKSERVER_QuickConnect_LetsEncrypt_CertType}" == "Production" || "${TAKSERVER_QuickConnect_LetsEncrypt_CertType}" == "Staging" ) \
    ]]; then
    # Previous LetsEncrypt cert exists, convert it to JKS format
    echo "TAK Server - Converting LetsEncrypt certs to TAK format"
    openssl x509 \
        -text \
        -in "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" \
        -noout

    openssl pkcs12 \
        -export \
        -in "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" \
        -inkey "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/privkey.pem" \
        -out "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.p12" \
        -name "${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" \
        -password "pass:atakatak"

    { yes || :; } | keytool \
        -importkeystore \
        -srcstorepass "atakatak" \
        -deststorepass "atakatak" \
        -destkeystore "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks" \
        -srckeystore "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.p12" \
        -srcstoretype "pkcs12" 
else 
    # No previous LetsEncrypt cert exists or settings call for none to be used, use the self-signed one instead
    echo "TAK Server - Using self-signed certs instead of LetsEncrypt certs"
    cp /opt/tak/certs/files/takserver.jks /opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks || true
fi


# Request LetsEncrypt certs in background
/opt/tak/scripts/letsencrypt-request-cert.sh &
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
#npx tsx /opt/tak/scripts/CoreConfig.ts
/opt/tak/scripts/createCoreConfig.sh /opt/tak/CoreConfig.xml

echo "TAK Server - Validating config file"
/opt/tak/validateConfig.sh /opt/tak/CoreConfig.xml

echo "TAK Server - Validate DB schema"
java -jar /opt/tak/db-utils/SchemaManager.jar validate
java -jar /opt/tak/db-utils/SchemaManager.jar upgrade

echo "TAK Server - Starting server"

# Start cron in background
echo "Certbot - Starting cron for certbot renewals"
/usr/sbin/cron &
CRON_PID=$!

# Start admin user elevation in background
(
    sleep 10
    echo "TAK Server - Starting to elevate admin user privileges..."
    SetAdminCommand="java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem"
    while ! $SetAdminCommand; do
       echo "TAK Server - Elevating admin user privileges failed, retrying in 10 seconds..."
       sleep 10
    done
    echo "TAK Server - Elevating admin user privileges succeeded"
) &

echo "TAK Server - New ECS Task successfully started"

# Run TAK server as main process (not in background)
echo "TAK Server - Starting main TAK server process..."
exec /opt/tak/configureInDocker.sh init
