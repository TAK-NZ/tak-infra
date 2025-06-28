#!/bin/bash
set -euo pipefail

# Validate required environment variables
validate_environment() {
    local missing_vars=()
    
    [[ -z "${ECS_Cluster_Name:-}" ]] && missing_vars+=("ECS_Cluster_Name")
    [[ -z "${ECS_Service_Name:-}" ]] && missing_vars+=("ECS_Service_Name")
    [[ -z "${TAKSERVER_QuickConnect_LetsEncrypt_Email:-}" ]] && missing_vars+=("TAKSERVER_QuickConnect_LetsEncrypt_Email")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "Error: Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
}

# Function to trigger ECS deployment
trigger_ecs_deployment() {
    echo "Certbot - Triggering ECS service deployment..."
    if ! aws ecs update-service --cluster "${ECS_Cluster_Name}" --service "${ECS_Service_Name}" --force-new-deployment 2>/tmp/aws_error.log; then
        echo "Error: Failed to update ECS service"
        echo "AWS CLI Error:"
        cat /tmp/aws_error.log
        return 1
    fi
}

# Function to determine certificate action
determine_cert_action() {
    local issuer="$1"
    local requested_type="${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}"
    
    case "$issuer" in
        *STAGING*)
            case "$requested_type" in
                "staging") echo "keep" ;;
                "production") echo "regenerate" ;;
                *) echo "fallback" ;;
            esac
            ;;
        *"Let's Encrypt"*)
            case "$requested_type" in
                "production") echo "keep" ;;
                "staging") echo "regenerate" ;;
                *) echo "fallback" ;;
            esac
            ;;
        *)
            case "$requested_type" in
                "production"|"staging") echo "regenerate" ;;
                *) echo "fallback" ;;
            esac
            ;;
    esac
}

# Function to validate certbot command
validate_certbot_command() {
    local domain="$1"
    local email="$2"
    
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,61}[a-zA-Z0-9]?\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: Invalid domain format: $domain"
        return 1
    fi
    
    if [[ ! "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        echo "Error: Invalid email format: $email"
        return 1
    fi
    
    if ! command -v certbot >/dev/null 2>&1; then
        echo "Error: certbot command not found"
        return 1
    fi
    
    return 0
}

# Function to execute certbot with logging
execute_certbot() {
    local domain="$1"
    local email="$2"
    local test_cert_flag="$3"
    
    local masked_email="${email%%@*}@***"
    echo "Certbot - Executing: certbot certonly -v ${test_cert_flag}--standalone -d \"$domain\" --email \"$masked_email\" --non-interactive --agree-tos"
    
    certbot certonly -v ${test_cert_flag}--standalone \
        -d "$domain" \
        --email "$email" \
        --non-interactive \
        --agree-tos \
        --cert-name "$domain" \
        --deploy-hook /opt/tak/scripts/letsencrypt-deploy-hook-script.sh
}

# Validate environment before proceeding
validate_environment

# Check if TAKSERVER_QuickConnect_LetsEncrypt_Domain is specified and a Let's Encrypt cert is requested
if [[ -z "${TAKSERVER_QuickConnect_LetsEncrypt_Domain+x}" || \
    -z "${TAKSERVER_QuickConnect_LetsEncrypt_CertType+x}" || \
    ( "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" != "production" && "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" != "staging" ) \
    ]]; then
    echo "TAK Server - Using self-signed certs instead of LetsEncrypt certs"
    mkdir -p "/opt/tak/certs/files/nodomainset" || true
    cp "/opt/tak/certs/files/takserver.jks" "/opt/tak/certs/files/nodomainset/letsencrypt.jks" || true        
    exit 0
fi

# If LetsEncrypt certs are present - check validity
if [ -d "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" ]; then
    echo "Certbot - Checking validity of existing certs for domain ${TAKSERVER_QuickConnect_LetsEncrypt_Domain}"

    # Extract the issuer from the certificate
    ISSUER=$(openssl x509 -noout -issuer -in "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem")
    
    # Determine action based on certificate type and request
    ACTION=$(determine_cert_action "$ISSUER")
    
    case "$ACTION" in
        "keep")
            echo "Certbot - Certificate exists and matches request - Nothing to be done"
            exit 0
            ;;
        "regenerate")
            echo "Certbot - Certificate type mismatch - Regenerating certs..."
            certbot delete --cert-name "${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" --non-interactive || true
            ;;
        "fallback")
            echo "Certbot - Using self-signed certs instead of LetsEncrypt..."
            cp "/opt/tak/certs/files/takserver.jks" "/opt/tak/certs/files/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/letsencrypt.jks" || true
            trigger_ecs_deployment
            exit 0
            ;;
    esac
fi

# Function to check ECS service readiness
check_ecs_service_ready() {
    local max_wait_time=${ECS_READINESS_TIMEOUT:-900}
    local check_interval=30
    local max_attempts=$((max_wait_time / check_interval))
    
    echo "Certbot - Waiting for ECS service (timeout: ${max_wait_time}s)..."
    
    for i in $(seq 1 $max_attempts); do
        local service_status
        if ! service_status=$(aws ecs describe-services \
            --cluster "${ECS_Cluster_Name}" \
            --services "${ECS_Service_Name}" \
            --query 'services[0].deployments[?status==`PRIMARY`].runningCount' \
            --output text 2>/tmp/aws_error.log); then
            
            echo "Warning: Failed to check ECS service status"
            echo "AWS CLI Error:"
            cat /tmp/aws_error.log
            return 1
        fi
        
        if [[ "$service_status" =~ ^[0-9]+$ ]] && [ "$service_status" -gt 0 ]; then
            echo "Certbot - ECS service ready after $((i * check_interval))s"
            return 0
        fi
        
        if [[ "$service_status" == "None" ]] && [ $i -gt 5 ]; then
            echo "Certbot - ECS service not found, continuing anyway..."
            return 0
        fi
        
        echo "Certbot - ECS service not ready, waiting ${check_interval}s... (${i}/${max_attempts})"
        sleep $check_interval
    done
    
    echo "Certbot - ECS service check timed out after ${max_wait_time}s, proceeding anyway..."
    return 0
}

# If no LetsEncrypt certs are present - either because they never were or they were just removed - generate a set
if [ ! -d "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" ]; then
    echo "Certbot - No existing certificates detected - Requesting new one for domain ${TAKSERVER_QuickConnect_LetsEncrypt_Domain}"

    # Validate certbot command before proceeding
    if ! validate_certbot_command "${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" "${TAKSERVER_QuickConnect_LetsEncrypt_Email}"; then
        exit 1
    fi
    
    # Wait for ECS service to be ready
    check_ecs_service_ready

    CertbotParameter=""
    if [ "${TAKSERVER_QuickConnect_LetsEncrypt_CertType,,}" != "production" ]; then
        CertbotParameter="--test-cert "
    fi

    for i in {1..10}; do
        if execute_certbot "${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" "${TAKSERVER_QuickConnect_LetsEncrypt_Email}" "${CertbotParameter}"; then
            break
        fi
        if [ $i -eq 10 ]; then
            echo "Certbot - Failed after 10 attempts. Check firewall/security group settings for port 80."
            exit 1
        fi
        echo "Certbot - Attempt $i/10 failed. Port TCP/80 not ready for HTTP-01 challenge - Retrying in 30 seconds..."
        sleep 30
    done

    # Save Certbot Cronjob
    cp "/etc/cron.d/certbot" "/etc/letsencrypt/certbot.cron"

    echo "Certbot - New LetsEncrypt certs issued - Deploying new ECS task..."

    trigger_ecs_deployment
fi
