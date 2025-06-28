#!/bin/bash
#
# Certbot deploy hook script for ECS service updates
# Triggered after successful certificate renewal to restart TAK Server
#
set -euo pipefail

# Validate required environment variables
if [[ -z "${ECS_Cluster_Name:-}" ]]; then  
  echo "Error: ECS_Cluster_Name not set. Exiting script."  
  exit 1  
fi

if [[ -z "${ECS_Service_Name:-}" ]]; then  
  echo "Error: ECS_Service_Name not set. Exiting script."  
  exit 1  
fi

# Validate AWS CLI availability
if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI not found"
    exit 1
fi

echo "Certbot deploy hook triggered - updating ECS service ${ECS_Service_Name} in cluster ${ECS_Cluster_Name}"

# Update ECS service with retry logic
for i in {1..3}; do
    if aws ecs update-service --cluster "${ECS_Cluster_Name}" --service "${ECS_Service_Name}" --force-new-deployment 2>/tmp/aws_error.log; then
        echo "ECS service update successful"
        exit 0
    fi
    
    if [ $i -eq 3 ]; then
        echo "Error: Failed to update ECS service after 3 attempts"
        echo "AWS CLI Error:"
        cat /tmp/aws_error.log
        exit 1
    fi
    
    echo "ECS service update attempt $i/3 failed, retrying in 5 seconds..."
    sleep 5
done