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
