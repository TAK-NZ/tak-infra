#!/bin/bash

# Check if TAKSERVER_QuickConnect_LetsEncrypt_Domain is specified and a Let's Encrypt cert is requested
if [[ -z "${TAKSERVER_QuickConnect_LetsEncrypt_Domain+x}" || \
    -z "${TAKSERVER_QuickConnect_LetsEncrypt_CertType+x}" || \
    ( "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" != "production" && "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" != "staging" ) \
    ]]; then
    echo "TAK Server - Using self-signed certs instead of LetsEncrypt certs"
    mkdir /opt/tak/certs/files/nodomainset || true
    cp /opt/tak/certs/files/takserver.jks /opt/tak/certs/files/nodomainset/letsencrypt.jks || true        
    exit 0
fi

# If LetsEncrypt certs are present - check validity
if [ -d "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" ]; then
    echo "Certbot - Checking validity of existing certs for domain ${TAKSERVER_QuickConnect_LetsEncrypt_Domain}"

    # Extract the issuer from the certificate
    ISSUER=$(openssl x509 -noout -issuer -in "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem")

    # Check if the issuer is from the Let's Encrypt staging environment
    if echo "$ISSUER" | grep -q "STAGING"; then
        if [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "staging" ]; then
            echo "Certbot - Staging cert exists, Staging cert requested - Nothing to be done"
        elif [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "production" ]; then
            echo "Certbot - Staging cert exists, Production cert requested - Regenerating certs..."
            certbot delete --cert-name ${TAKSERVER_QuickConnect_LetsEncrypt_Domain} --non-interactive    
        else
            echo "Certbot - Staging cert exists, No cert requested - Using self-signed certs..."
            cp /opt/tak/certs/files/takserver.jks /opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks || true
            aws ecs update-service --cluster $ECS_Cluster_Name --service $ECS_Service_Name --force-new-deployment
            exit 0
        fi
    # Check if the issuer is from the Let's Encrypt production environment        
    elif echo "$ISSUER" | grep -q "Let's Encrypt"; then
        if [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "production" ]; then
            echo "Certbot - Production cert exists, Production cert requested - Nothing to be done"
        elif [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "staging" ]; then
            echo "Certbot - Production cert exists, Staging cert requested - Regenerating certs..."
            certbot delete --cert-name ${TAKSERVER_QuickConnect_LetsEncrypt_Domain} --non-interactive
        else 
            echo "Certbot - Production cert exists, No cert requested - Using self-signed certs..."
            cp /opt/tak/certs/files/takserver.jks /opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks || true
            aws ecs update-service --cluster $ECS_Cluster_Name --service $ECS_Service_Name --force-new-deployment
            exit 0
        fi
    else
        if [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "production" ]; then
            echo "Certbot - No cert exists, Production cert requested - Regenerating certs..."
            certbot delete --cert-name ${TAKSERVER_QuickConnect_LetsEncrypt_Domain} --non-interactive || true
        elif [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" == "staging" ]; then
            echo "Certbot - No cert exists, Staging cert requested - Regenerating certs..."
            certbot delete --cert-name ${TAKSERVER_QuickConnect_LetsEncrypt_Domain} --non-interactive || true
        else
            echo "Certbot - No cert exists, No cert requested - Using self-signed certs..."
            cp /opt/tak/certs/files/takserver.jks /opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks || true
            aws ecs update-service --cluster $ECS_Cluster_Name --service $ECS_Service_Name --force-new-deployment
            exit 0
        fi
    fi
fi

# If no LetsEncrypt certs are present - either because they never were or they were just removed - generate a set
if [ ! -d "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" ]; then
    echo "Certbot - No existing certificates detected - Requesting new one for domain ${TAKSERVER_QuickConnect_LetsEncrypt_Domain}"

    CertbotParameter=""
    if [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" != "production" ]; then
        CertbotParameter="--test-cert "
    fi
   
    Command="certbot certonly -v ${CertbotParameter}--standalone -d ${TAKSERVER_QuickConnect_LetsEncrypt_Domain} --email ${TAKSERVER_QuickConnect_LetsEncrypt_Email} --non-interactive --agree-tos --cert-name ${TAKSERVER_QuickConnect_LetsEncrypt_Domain} --deploy-hook /opt/tak/scripts/letsencrypt-deploy-hook-script.sh"

    RETRY_COUNT=0
    MAX_RETRIES=10
    
    while ! $Command; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            echo "Certbot - Failed after $MAX_RETRIES attempts. Check firewall/security group settings for port 80."
            exit 1
        fi
        echo "Certbot - Attempt $RETRY_COUNT/$MAX_RETRIES failed. Port TCP/80 not ready for HTTP-01 challenge - Retrying in 30 seconds..."
        sleep 30
    done

    # Save Certbot Cronjob
    cp /etc/cron.d/certbot /etc/letsencrypt/certbot.cron

    echo "Certbot - New LetsEncrypt certs issued - Deploying new ECS task..."

    aws ecs update-service --cluster $ECS_Cluster_Name --service $ECS_Service_Name --force-new-deployment
fi
