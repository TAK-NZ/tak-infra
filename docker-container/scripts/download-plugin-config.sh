#!/bin/bash
# Download TAK-GPT plugin configuration from S3
set -euo pipefail

PLUGIN_CONF_DIR="/opt/tak/conf/plugins"
S3_BUCKET="${S3_TAK_CONFIG_BUCKET:-}"
PLUGIN_PREFIX="takserver-plugins/tak-gpt"

if [ -z "$S3_BUCKET" ]; then
    echo "TAK-GPT Plugin - S3_TAK_CONFIG_BUCKET not set, skipping plugin config download"
    exit 0
fi

echo "TAK-GPT Plugin - Downloading configuration from s3://${S3_BUCKET}/${PLUGIN_PREFIX}/"

mkdir -p "$PLUGIN_CONF_DIR"

# Download YAML config
if aws s3 cp "s3://${S3_BUCKET}/${PLUGIN_PREFIX}/tak.server.plugins.TAKChatBotBase.yaml" \
    "$PLUGIN_CONF_DIR/" 2>/dev/null; then
    echo "TAK-GPT Plugin - Downloaded YAML configuration"
else
    echo "TAK-GPT Plugin - YAML config not found in S3, skipping"
fi

# Download RAG prompt
if aws s3 cp "s3://${S3_BUCKET}/${PLUGIN_PREFIX}/nz_rag_responder.txt" \
    "$PLUGIN_CONF_DIR/" 2>/dev/null; then
    echo "TAK-GPT Plugin - Downloaded RAG prompt"
else
    echo "TAK-GPT Plugin - RAG prompt not found in S3, skipping"
fi

# Set permissions
chown -R 1000:1000 "$PLUGIN_CONF_DIR" 2>/dev/null || true

echo "TAK-GPT Plugin - Configuration download complete"
