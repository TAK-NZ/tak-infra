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
    
    # Clean up any existing LetsEncrypt certificates if switching away from LetsEncrypt
    if [[ -n "${TAKSERVER_QuickConnect_LetsEncrypt_Domain:-}" && -f "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" ]]; then
        echo "Certbot - Cleaning up existing LetsEncrypt certificates"
        certbot delete --cert-name "${TAKSERVER_QuickConnect_LetsEncrypt_Domain}" --non-interactive || true
        trigger_ecs_deployment
    fi
    
    mkdir -p "/opt/tak/certs/files/nodomainset" || true
    cp "/opt/tak/certs/files/takserver.jks" "/opt/tak/certs/files/nodomainset/letsencrypt.jks" || true        
    exit 0
fi

# If LetsEncrypt certs are present - check validity
if [ -f "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" ]; then
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

# Function to check ECS service readiness and ensure this task is the only one receiving traffic
check_ecs_service_ready() {
    local max_wait_time=${ECS_READINESS_TIMEOUT:-900}
    local check_interval=30
    local max_attempts=$((max_wait_time / check_interval))
    
    echo "Certbot - Waiting for ECS service and load balancer readiness (timeout: ${max_wait_time}s)..."
    
    for i in $(seq 1 $max_attempts); do
        # Step 1: Check exactly 1 task is running
        local running_count
        if ! running_count=$(aws ecs describe-services \
            --cluster "${ECS_Cluster_Name}" \
            --services "${ECS_Service_Name}" \
            --query 'services[0].runningCount' \
            --output text 2>/tmp/aws_error.log); then
            
            echo "Warning: Failed to check ECS service status"
            cat /tmp/aws_error.log
            sleep $check_interval
            continue
        fi
        
        if [[ "$running_count" != "1" ]]; then
            echo "Certbot - Waiting for exactly 1 running task (current: $running_count)..."
            sleep $check_interval
            continue
        fi
        
        # Step 2: Get this task's private IP
        local task_arn
        if ! task_arn=$(aws ecs list-tasks \
            --cluster "${ECS_Cluster_Name}" \
            --service-name "${ECS_Service_Name}" \
            --query 'taskArns[0]' \
            --output text 2>/tmp/aws_error.log); then
            
            echo "Warning: Failed to get task ARN"
            cat /tmp/aws_error.log
            sleep $check_interval
            continue
        fi
        
        local task_ip
        if ! task_ip=$(aws ecs describe-tasks \
            --cluster "${ECS_Cluster_Name}" \
            --tasks "$task_arn" \
            --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' \
            --output text 2>/tmp/aws_error.log); then
            
            echo "Warning: Failed to get task IP"
            cat /tmp/aws_error.log
            sleep $check_interval
            continue
        fi
        
        # Step 3: Find the HTTP target group (certbot target group)
        local target_group_arn
        if ! target_group_arn=$(aws elbv2 describe-target-groups \
            --names "tak-*-certbot" \
            --query 'TargetGroups[0].TargetGroupArn' \
            --output text 2>/tmp/aws_error.log); then
            
            echo "Warning: Failed to find certbot target group"
            cat /tmp/aws_error.log
            sleep $check_interval
            continue
        fi
        
        # Step 4: Check if this task is healthy in target group
        local healthy_targets
        if ! healthy_targets=$(aws elbv2 describe-target-health \
            --target-group-arn "$target_group_arn" \
            --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id' \
            --output text 2>/tmp/aws_error.log); then
            
            echo "Warning: Failed to check target health"
            cat /tmp/aws_error.log
            sleep $check_interval
            continue
        fi
        
        # Step 5: Verify only this task's IP is healthy
        local healthy_count=$(echo "$healthy_targets" | wc -w)
        if [[ "$healthy_count" -eq 1 && "$healthy_targets" == "$task_ip" ]]; then
            echo "Certbot - ECS service ready: 1 task running, this task ($task_ip) is sole healthy target"
            return 0
        fi
        
        echo "Certbot - Waiting for load balancer: healthy_targets=[$healthy_targets], this_task=$task_ip"
        sleep $check_interval
    done
    
    echo "Certbot - Load balancer check timed out, falling back to basic ECS check..."
    
    # Fallback to original simple check
    local service_status
    if service_status=$(aws ecs describe-services \
        --cluster "${ECS_Cluster_Name}" \
        --services "${ECS_Service_Name}" \
        --query 'services[0].deployments[?status==`PRIMARY`].runningCount' \
        --output text 2>/dev/null) && [[ "$service_status" =~ ^[0-9]+$ ]] && [ "$service_status" -gt 0 ]; then
        
        echo "Certbot - Proceeding with basic readiness check (load balancer verification failed)"
        return 0
    fi
    
    echo "Certbot - Service not ready after ${max_wait_time}s, proceeding anyway..."
    return 0
}

# If no LetsEncrypt certs are present - either because they never were or they were just removed - generate a set
if [ ! -f "/etc/letsencrypt/live/${TAKSERVER_QuickConnect_LetsEncrypt_Domain}/fullchain.pem" ]; then
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
