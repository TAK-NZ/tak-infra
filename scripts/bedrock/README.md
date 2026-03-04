# Bedrock Agent Setup

## Prerequisites

- BaseInfra stack deployed (`TAK-<Environment>-BaseInfra`)
- AWS CLI configured with appropriate profile
- `opensearch-py` and `requests-aws4auth` installed: `pip install opensearch-py requests-aws4auth`

## Setup

Creates an OpenSearch Serverless collection, Bedrock Knowledge Base, and Bedrock Agent with a `RETURN_CONTROL` action group for TAK map marker creation. IDs are written to SSM Parameter Store.

```bash
python3 scripts/bedrock/setup-bedrock-agent.py \
  --environment Demo \
  --kb-name nema-cdem \
  --agent-name "NEMA CDEM Bot" \
  --system-prompt-file scripts/bedrock/nz_rag_responder.txt \
  [--profile my-aws-profile]
```

SSM parameters written to `/tak/<environment-lowercase>/bedrock/<kb-name>/`:
- `agent-id`
- `agent-alias-id`
- `kb-id`

## Adding Documents

Upload PDFs to the S3 prefix `bedrock-kb/<kb-name>/` in the artifacts bucket, then trigger a sync:

```bash
# Sync knowledge base after uploading new documents
KB_ID=$(aws ssm get-parameter --name /tak/demo/bedrock/nema-cdem/kb-id --query 'Parameter.Value' --output text)
DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --query 'dataSourceSummaries[0].dataSourceId' --output text)
aws bedrock-agent start-ingestion-job --knowledge-base-id $KB_ID --data-source-id $DS_ID
```

Sync typically takes 1–5 minutes depending on document count. Check status:

```bash
aws bedrock-agent list-ingestion-jobs --knowledge-base-id $KB_ID --data-source-id $DS_ID \
  --query 'ingestionJobSummaries[0].{status:status,updated:updatedAt}' --output json
```

## Bot Configuration

Add to the bot YAML config (IDs from SSM or script output):

```yaml
modelType: bedrock
agentId: <agent-id>
agentAliasId: <agent-alias-id>
region: us-west-2
```

## Re-running

The script is idempotent — safe to re-run. It will skip already-created resources and attach the KB to the agent if not already associated.
