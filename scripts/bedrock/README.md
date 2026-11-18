# Bedrock Agent Setup

## Prerequisites

- BaseInfra stack deployed (`TAK-<Environment>-BaseInfra`)
- TakInfra stack deployed (`TAK-<Environment>-TakInfra`) with the knowledge base name listed in `bedrock.knowledgeBases` (`cdk.json`, or `--context bedrockKnowledgeBases=nema-cdem,nzdf`). The stack creates the knowledge base; this script does not.
- AWS CLI configured with appropriate profile
- `boto3` installed

## Setup

Creates (or updates) the Bedrock Agent with its action groups, including the `RETURN_CONTROL` group for TAK map marker creation, and an alias. IDs are written to SSM Parameter Store.

The knowledge base is created by the TakInfra CDK stack (`lib/constructs/bedrock-knowledge-base.ts`): an Amazon S3 Vectors index, the knowledge base role, the knowledge base (named `<kb-name>-s3v`) and an S3 data source on `bedrock-kb/<kb-name>/`. The script reads its ID from the stack outputs (`BedrockKb<Name>Id`, `nema-cdem` becomes `NemaCdem`). If the knowledge base has never been ingested, the script starts an ingestion job and waits for it before it attaches the knowledge base to the agent. If the agent still has another knowledge base attached (the old OpenSearch one), the script detaches it.

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

Bedrock Knowledge Base supports: PDF, plain text, markdown, HTML, Word (.docx), and CSV. Upload files to the S3 prefix `bedrock-kb/<kb-name>/` in the artifacts bucket, then trigger a sync.

### Preparing KML/KMZ Files

KML and KMZ are not supported natively — convert to CSV first using `ogr2ogr` (part of GDAL):

```bash
# KMZ
ogr2ogr -f CSV output_raw.csv /vsizip/input.kmz -lco GEOMETRY=AS_XY

# KML
ogr2ogr -f CSV output_raw.csv input.kml -lco GEOMETRY=AS_XY
```

This produces `X` (longitude) and `Y` (latitude) columns alongside the feature attributes. Then:

1. Rename `X`/`Y` to `lon`/`lat` so the agent understands them:
   ```bash
   sed -i '1s/^X,Y/lon,lat/' output_raw.csv
   ```

2. Remove KML artefact columns that add noise (`timestamp`, `begin`, `end`, `altitudeMode`, `tessellate`, `extrude`, `visibility`, `drawOrder`, `icon`, `GlobalID` etc.) — keep only operationally useful fields:
   ```bash
   # Example using csvkit (pip install csvkit)
   csvcut -c lon,lat,Name,Type,Address,Phone output_raw.csv > output.csv
   ```

If GDAL is not available, [MyGeodata Converter](https://mygeodata.cloud/converter/kml-to-csv) converts KML/KMZ to CSV online.

### Syncing after Upload

Upload PDFs to the S3 prefix `bedrock-kb/<kb-name>/` in the artifacts bucket, then trigger a sync:

```bash
# Sync knowledge base after uploading new documents
KB_ID=$(aws ssm get-parameter --name /tak/demo/bedrock/nema-cdem/kb-id --query 'Parameter.Value' --output text)
DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --query 'dataSourceSummaries[0].dataSourceId' --output text)
aws bedrock-agent start-ingestion-job --knowledge-base-id $KB_ID --data-source-id $DS_ID
```

Sync takes about 1 minute for a few documents and about 13 minutes for 35 MB of PDFs. Check status:

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

## Moving an environment from the OpenSearch knowledge base to S3 Vectors
Do this once per environment, after the stack with `bedrock.knowledgeBases` is deployed:
1. Run `setup-bedrock-agent.py` as above. It syncs the new knowledge base, attaches it to the agent and detaches the old one.
2. Ask the bot a few questions that need the documents. To go back, attach the old knowledge base to the agent again (`aws bedrock-agent associate-agent-knowledge-base`), detach the new one and prepare the agent.
3. When satisfied, delete the old resources, which stop the OpenSearch OCU charge: the old knowledge base (`<kb-name>`, not `<kb-name>-s3v`), the OpenSearch Serverless collection `<kb-name>` with its policies `<kb-name>-enc`, `<kb-name>-net` and `<kb-name>-access`, and the IAM role `BedrockKBRole-<kb-name>`.
