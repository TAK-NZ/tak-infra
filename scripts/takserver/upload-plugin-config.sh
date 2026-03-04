#!/bin/bash
# Upload TAK-GPT plugin configuration to S3
set -euo pipefail

ENVIRONMENT=${1:-}
YAML_CONFIG=${2:-}
RAG_PROMPT=${3:-}

if [ -z "$ENVIRONMENT" ] || [ -z "$YAML_CONFIG" ] || [ -z "$RAG_PROMPT" ]; then
    echo "Usage: $0 <environment> <yaml-config-file> <rag-prompt-file>"
    echo ""
    echo "Example:"
    echo "  $0 Dev tak.server.plugins.TAKChatBotBase.yaml nz_rag_responder.txt"
    echo "  $0 Prod tak.server.plugins.TAKChatBotBase.yaml nz_rag_responder.txt"
    exit 1
fi

if [ ! -f "$YAML_CONFIG" ]; then
    echo "Error: YAML config file not found: $YAML_CONFIG"
    exit 1
fi

if [ ! -f "$RAG_PROMPT" ]; then
    echo "Error: RAG prompt file not found: $RAG_PROMPT"
    exit 1
fi

echo "Getting S3 bucket name from CloudFormation..."
BUCKET_ARN=$(aws cloudformation describe-stacks \
    --stack-name "TAK-${ENVIRONMENT}-BaseInfra" \
    --query 'Stacks[0].Outputs[?OutputKey==`S3EnvConfigArnOutput`].OutputValue' \
    --output text)

if [ -z "$BUCKET_ARN" ]; then
    echo "Error: Could not find S3 config bucket ARN from stack TAK-${ENVIRONMENT}-BaseInfra"
    exit 1
fi

BUCKET_NAME=$(echo "$BUCKET_ARN" | sed 's|arn:aws:s3:::||')
echo "Using S3 bucket: $BUCKET_NAME"

echo ""
echo "Uploading plugin configuration files..."
aws s3 cp "$YAML_CONFIG" "s3://${BUCKET_NAME}/takserver-plugins/tak-gpt/tak.server.plugins.TAKChatBotBase.yaml"
aws s3 cp "$RAG_PROMPT" "s3://${BUCKET_NAME}/takserver-plugins/tak-gpt/nz_rag_responder.txt"

echo ""
echo "✓ Plugin configuration uploaded successfully!"
echo ""
echo "To apply the configuration, restart the TAK Server ECS service:"
echo "  aws ecs update-service \\"
echo "    --cluster TAK-${ENVIRONMENT}-BaseInfra-EcsCluster \\"
echo "    --service TAK-${ENVIRONMENT}-TakInfra-TakServer \\"
echo "    --force-new-deployment"
