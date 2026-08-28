# Bedrock Agents Classic → AgentCore Migration

> **Status: not implemented.** This is a design/roadmap document, not a
> description of the current deployment. All work described here is tracked
> in GitHub issue [#157](https://github.com/TAK-NZ/tak-infra/issues/157) and
> its sub-issues (#158–#161). Check those issues for current status before
> assuming anything below is built. This doc lives in `docs/roadmap/`
> specifically to keep unimplemented design work visually and physically
> separate from `docs/` (which documents the system as it actually exists
> today).
>
> **Repo decision: stays in `tak-infra`, not a new `bedrock-infra` repo.**
> The section below ("Repo Layout: `bedrock-infra`") reflects the original
> proposal and is kept for its analysis of what's shared vs. not, but the
> conclusion changed: `utils-infra`'s Bedrock usage (SitRep Lambda) calls
> `InvokeModel` directly with no Agent/KB/AOSS involved, so it isn't actually
> a consumer of these resources, and the Agent's `RETURN_CONTROL` tool
> contract is inherently coupled to the ATAK bot/TAK-GPT plugin here. See
> #157 for the full reasoning. The CDK-ification and AgentCore/Strands
> migration steps below are unaffected by this — only the repo location
> changes (read `tak-infra` wherever the steps below say `bedrock-infra`).
> One addition not in the original proposal: a CloudTAK-awareness tool
> (#160), giving the agent live map data via the same CloudTAK REST API
> `utils-infra`'s SitRep Lambda already uses.

## Background

Amazon Bedrock Agents Classic is now in **maintenance mode**. It is closed to new customers from July 30, 2026. Existing accounts can continue running but AWS is not developing it further. The recommended replacement is **Amazon Bedrock AgentCore**, which launched GA in June 2026.

This migration is also a good point to make two structural changes to how these resources are managed:

1. **Move from an imperative Python script to CDK.** The current `setup-bedrock-agent.py` script hand-rolls IAM role creation, OpenSearch Serverless (AOSS) collection/index provisioning (including manually SigV4-signing HTTP requests), Knowledge Base creation, and Agent lifecycle management, with manual `time.sleep()` calls standing in for what CloudFormation already does natively. CDK now has stable L1 (`Cfn*`) coverage for all of it: `aws-opensearchserverless` (`CfnCollection`, `CfnIndex`/`CfnCollectionIndex`, security policies), `aws-bedrock` (`CfnKnowledgeBase`, `CfnDataSource`, `CfnAgent`, `CfnAgentAlias`), and `aws-bedrockagentcore` (`CfnRuntime`, `CfnRuntimeEndpoint` — stable CloudFormation support since September 2025). Moving to CDK gives these resources the same versioning, diffing, and rollback safety as the rest of the infrastructure.
2. **Move the resources into a new, separate repo: `bedrock-infra`.** `tak-infra` was the first consumer of Bedrock (RELAY, SENTINEL), but `utils-infra` now has an independent use case for Bedrock too. Keeping the AOSS/KB/Agent resources inside `tak-infra` would force `utils-infra` to either duplicate them or reach sideways into `tak-infra`'s stack outputs — a sibling-to-sibling dependency the existing layering avoids. A dedicated `bedrock-infra` repo, deployed as a sibling of `auth-infra`/`tak-infra`/`utils-infra` (all depending only on `base-infra`), keeps Bedrock as shared infrastructure that any consumer can use.

This document covers the migration path for the two agents that exist today:

| Agent | KB | System prompt |
|---|---|---|
| RELAY (TAK.NZ Intelligence Bot) | `nema-cdem` | `nz_rag_responder.txt` |
| SENTINEL (NZDF Doctrine & COP Bot) | NZDF KB | `nzdf_rag_responder.txt` |

---

## Understanding AgentCore

AgentCore has two deployment paths:

### Harness (managed loop)
AWS runs the full orchestration loop for you (powered by Strands Agents). You declare the agent as configuration — model, system prompt, tools, memory. Low-code, close to the Bedrock Agents Classic experience.

**Limitation for this project:** Harness has no `RETURN_CONTROL` equivalent. All tools must either be Lambda-backed or MCP-served. This is a fundamental blocker given how TAK tool invocations work (see below).

### Runtime (bring-your-own-agent)
You provide the agent loop code as a containerised Python application. AgentCore provides the serverless compute, memory, tool gateway, identity, and observability around it. You can use any framework — Strands, LangGraph, plain Python. `RETURN_CONTROL` is fully supported because you control the loop.

---

## RETURN_CONTROL — Recommendation

### Why it matters here

The `tak-tools` action group uses `RETURN_CONTROL`. When the agent decides to call `create_tak_map_marker`, it does not invoke a Lambda — it returns the tool call back to the ATAK client application, which then directly injects the CoT message into the TAK network. This is intentional: map marker creation is a client-side operation in the TAK ecosystem and cannot be handled by a backend Lambda.

The same pattern applies to any future TAK client operations the agent might need to perform, for example:

- Drawing shapes or polygons on the COP
- Setting or clearing emergency alerts
- Updating a unit's callsign or CoT type
- Triggering an evacuation overlay
- Dropping multiple markers from a list
- Sending a group chat message from the bot

All of these are TAK client-side actions that must be handled by the calling application, not a Lambda. `RETURN_CONTROL` is the architecturally correct pattern for this class of operation and will only become more important as capabilities grow.

### Recommendation: AgentCore Runtime + Strands SDK

Use **AgentCore Runtime** with the **AWS Strands Agents SDK** as the orchestration framework.

This gives you:

- Full `RETURN_CONTROL` support — the agent loop is your code, so you intercept tool calls exactly as today
- A clean, minimal agent loop (Strands reduces it to ~30–50 lines for the core)
- Native AgentCore Memory, Observability, Gateway, and Identity integration
- A path to add any future TAK tool as a new `@tool` decorated function with no architectural changes
- Framework alignment with where AWS is investing — Strands is the framework Harness uses internally

The tradeoff vs Harness is that you own a container and a small amount of orchestration code. Given the `RETURN_CONTROL` requirement that is unavoidable regardless of which path you take.

---

## Repo Layout: `bedrock-infra`

### Why a new repo instead of `tak-infra`

`tak-infra`'s `bedrock-geojson-lambda.ts` / `bedrock-arcgis-lambda.ts` constructs and the `setup-bedrock-agent.py` script were written when TAK-GPT (RELAY/SENTINEL) was the only Bedrock consumer. That's no longer true — `utils-infra` has its own Bedrock use case. Bedrock/AgentCore resources (AOSS collection, Knowledge Base, Agent/AgentCore Runtime, the generic tool Lambdas) are shared infrastructure, not a TAK-server-specific feature, so they belong in their own repo rather than inside `tak-infra`.

### Where it sits in the deployment graph

`bedrock-infra` only needs the artifacts S3 bucket and KMS key from `base-infra` (same imports `tak-infra` and `utils-infra` already use via `cloudformation-imports.ts`). It does not need the VPC, ECS cluster, or anything from `auth-infra` or `tak-infra`. That makes it a sibling stack, not a strict link in the existing chain:

```
base-infra
   ├── auth-infra
   ├── bedrock-infra   ← new repo, depends only on base-infra
   ├── tak-infra         (TAK-GPT bots read agent/KB IDs from SSM)
   └── utils-infra        (new Bedrock-backed service reads from SSM)
```

Consumers (`tak-infra`, `utils-infra`) don't need a CloudFormation cross-stack import or a hard deploy-order dependency on `bedrock-infra`. `bedrock-infra` writes `kb-id` / `agent-id` / `agent-alias-id` / `agent-runtime-id` to SSM Parameter Store (same mechanism the current script already uses), and consumers read those values at deploy or runtime. The only real ordering requirement is operational: the agent/KB needs to exist before a bot config or service references its ID.

### What moves into `bedrock-infra`

- The AOSS collection, security policies, and vector index
- The Bedrock Knowledge Base and its S3 data source
- The Agent / AgentCore Runtime and its IAM roles
- `bedrock-geojson-lambda.ts` and `bedrock-arcgis-lambda.ts` — these are generic (fetch a URL, call ArcGIS) and don't touch TAK server internals, so they move out of `tak-infra` to keep `bedrock-infra` self-contained
- The Strands agent runtime application (`src/bedrock-agent/`)
- The `nz_rag_responder.txt` / `nzdf_rag_responder.txt` system prompt files and other KB content helpers (`cot-types.txt`, `fire_stations.txt`, etc.)

### What stays in `tak-infra`

- The `tak-tools` action group definition is not a Lambda — it's a `RETURN_CONTROL` schema declaration with no execution backend, so it has no dependency direction either way. It can be defined in `bedrock-infra` alongside the Agent.
- The ATAK bot / TAK-GPT plugin code that reads `agent-id/agent-runtime-id` from SSM and calls `bedrock-agentcore-runtime`
- The `bedrock:InvokeModel*` / `bedrock:Retrieve*` / `bedrock:InvokeAgent` IAM permissions already granted to the TAK server ECS task role in `tak-server.ts` (these grant the *caller* permission to invoke the agent — they stay wherever the caller runs)

---

## What Does and Does Not Change

### Unchanged
- OpenSearch Serverless (AOSS) collection, encryption/network/access policies (now defined as CDK constructs instead of created imperatively)
- Bedrock Knowledge Base resources and data source configurations
- S3 document storage (`bedrock-kb/<kb-name>/`) — still in the `base-infra` artifacts bucket
- Knowledge base sync workflow (still a one-off operational action, not stack state)
- System prompt files (`nz_rag_responder.txt`, `nzdf_rag_responder.txt`)
- SSM parameter structure (same keys, same prefix)
- Bot YAML config structure (agent ID and alias/runtime ID references)

### Changes required
- **Resource management**: imperative `boto3` calls → CDK constructs (`CfnCollection`, `CfnIndex`, `CfnKnowledgeBase`, `CfnDataSource`, `CfnRuntime`)
- **Repo**: AOSS/KB/Agent/AgentCore resources and the GeoJSON/ArcGIS tool Lambdas move from `tak-infra` (`scripts/bedrock/`, `lib/constructs/bedrock-*-lambda.ts`) into a new `bedrock-infra` repo
- **Agent API**: `bedrock-agent` API → `bedrock-agentcore` API
- **IAM agent role**: new trust policy service principal condition ARN for AgentCore
- **Agent runtime**: new containerised Python app using Strands SDK, built as a CDK `DockerImageAsset` and deployed via `CfnRuntime` (no separate manual ECR push step)
- **Action groups** (`tak-tools`, `live-data`, `geocode`): replaced by Strands `@tool` definitions
- **Caller (ATAK bot / TAK-GPT plugin)**: invoke endpoint changes from `bedrock-agent-runtime` to `bedrock-agentcore-runtime`
- **`setup-bedrock-agent.py`**: retired entirely once the CDK stack is stable; any remaining manual step (KB document sync) becomes a short operational script or `README` command, not a stack-management script

---

## Migration Steps

### Step 1 — Verify existing resources are unaffected

Confirm that the AOSS collection and Bedrock Knowledge Base are still reachable and in ACTIVE/ACTIVE state. No changes are required to these resources yet. This is a good baseline check before starting, and gives you the resource IDs/ARNs to reconcile against once they're imported into CDK.

```bash
aws opensearchserverless list-collections --region ap-southeast-2
aws bedrock-agent list-knowledge-bases --region ap-southeast-2
```

### Step 2 — Scaffold the `bedrock-infra` repo

Create a new repo following the existing TAK-NZ CDK repo pattern (`bin/`, `lib/`, `cdk.json`, `package.json`, `test/`), modeled on `utils-infra`'s structure since it's the closest existing example of a `base-infra`-only sibling stack.

```
bedrock-infra/
├── bin/
│   └── bedrock-infra.ts
├── lib/
│   ├── bedrock-infra-stack.ts
│   ├── cloudformation-imports.ts     # import base-infra S3 bucket + KMS key ARNs
│   ├── stack-config.ts               # per-KB/agent config (name, kb-name, system-prompt-file)
│   └── constructs/
│       ├── aoss-collection.ts        # CfnCollection + security policies + CfnIndex
│       ├── knowledge-base.ts         # CfnKnowledgeBase + CfnDataSource + KB IAM role
│       ├── agent-runtime.ts          # CfnRuntime + DockerImageAsset + agent IAM role
│       ├── bedrock-geojson-lambda.ts # moved from tak-infra
│       └── bedrock-arcgis-lambda.ts  # moved from tak-infra
├── src/
│   └── bedrock-agent/
│       ├── agent.py
│       ├── Dockerfile
│       └── requirements.txt
├── cdk.json
├── package.json
└── test/
```

### Step 3 — Define the AOSS collection and Knowledge Base constructs

Port `ensure_aoss_collection`, `ensure_aoss_index`, `ensure_kb_iam_role`, and `ensure_knowledge_base` from the script into CDK constructs. This replaces the hand-rolled SigV4-signed HTTP index creation with a native `CfnIndex`/`CfnCollectionIndex` resource, and the manual `ACTIVE` polling with CloudFormation's built-in resource lifecycle handling.

```typescript
const collection = new opensearchserverless.CfnCollection(this, 'Collection', {
  name: kbName,
  type: 'VECTORSEARCH',
});

new opensearchserverless.CfnSecurityPolicy(this, 'EncryptionPolicy', {
  name: `${kbName}-enc`,
  type: 'encryption',
  policy: JSON.stringify({
    Rules: [{ ResourceType: 'collection', Resource: [`collection/${kbName}`] }],
    AWSOwnedKey: true,
  }),
});
// ...network + data access policies, then:
collection.addDependency(encryptionPolicy);

const index = new opensearchserverless.CfnIndex(this, 'VectorIndex', {
  collectionEndpoint: collection.attrCollectionEndpoint,
  indexName: kbName,
  mappings: { /* embedding / text / metadata fields, same shape as the script */ },
});

const kb = new bedrock.CfnKnowledgeBase(this, 'KnowledgeBase', {
  name: kbName,
  roleArn: kbRole.roleArn,
  knowledgeBaseConfiguration: {
    type: 'VECTOR',
    vectorKnowledgeBaseConfiguration: {
      embeddingModelArn: `arn:aws:bedrock:${region}::foundation-model/amazon.titan-embed-text-v2:0`,
    },
  },
  storageConfiguration: {
    type: 'OPENSEARCH_SERVERLESS',
    opensearchServerlessConfiguration: {
      collectionArn: collection.attrArn,
      vectorIndexName: kbName,
      fieldMapping: { vectorField: 'embedding', textField: 'text', metadataField: 'metadata' },
    },
  },
});
```

### Step 4 — Create the AgentCore agent IAM role

The role needs a trust policy scoped to the AgentCore agent-runtime ARN pattern rather than the classic agent ARN pattern.

```typescript
const agentRole = new iam.Role(this, 'AgentRole', {
  assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com', {
    conditions: {
      StringEquals: { 'aws:SourceAccount': Aws.ACCOUNT_ID },
      ArnLike: { 'aws:SourceArn': `arn:aws:bedrock-agentcore:${region}:${Aws.ACCOUNT_ID}:agent-runtime/*` },
    },
  }),
});
```

Permissions needed on the role:
- `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on `*`
- `bedrock:GetInferenceProfile` on foundation model and inference profile ARNs
- `bedrock:Retrieve` and `bedrock:RetrieveAndGenerate` on the knowledge base ARN
- `lambda:InvokeFunction` on the GeoJSON and ArcGIS Lambda ARNs (now siblings in the same stack)

### Step 5 — Write the Strands agent application

Create `src/bedrock-agent/agent.py` in the new repo.

The core pattern with Strands:

```python
import json
from strands import Agent, tool
from strands.models import BedrockModel

@tool
def query_geojson(url: str, lat: str = None, lon: str = None,
                  radius_km: str = None, filter_text: str = None) -> str:
    """Fetch live GeoJSON data from a URL and return matching features."""
    ...

@tool
def find_place(query: str, lat: str = None, lon: str = None) -> str:
    """Forward geocode a place name to coordinates."""
    ...

@tool
def reverse_geocode(lat: str, lon: str) -> str:
    """Reverse geocode coordinates to a street address."""
    ...

@tool
def create_tak_map_marker(type: str, callsign: str, lat: str, lon: str,
                          iconsetpath: str = None) -> dict:
    """
    Create a map marker in TAK at a specified location.
    Returns RETURN_CONTROL signal — the TAK client handles execution.
    """
    return {
        "returnControl": True,
        "function": "create_tak_map_marker",
        "parameters": {"type": type, "callsign": callsign,
                       "lat": lat, "lon": lon, "iconsetpath": iconsetpath}
    }

def create_agent(system_prompt: str, kb_id: str, region: str, model_id: str):
    model = BedrockModel(model_id=model_id, region_name=region)
    return Agent(
        model=model,
        system_prompt=system_prompt,
        tools=[query_geojson, find_place, reverse_geocode, create_tak_map_marker],
    )
```

Adding a new TAK capability in future is a single `@tool` decorated function. No action group API calls, no agent re-preparation cycle.

### Step 6 — Build and deploy the container via CDK

Instead of a manual `docker build` + `docker push` step, use a CDK `DockerImageAsset` so the image is built and pushed to ECR automatically as part of `cdk deploy`:

```typescript
const image = new ecrAssets.DockerImageAsset(this, 'AgentImage', {
  directory: path.join(__dirname, '../../src/bedrock-agent'),
});

const runtime = new bedrockagentcore.CfnRuntime(this, 'AgentRuntime', {
  agentRuntimeName: sanitizedName,
  agentRuntimeArtifact: {
    containerConfiguration: { containerUri: image.imageUri },
  },
  roleArn: agentRole.roleArn,
  networkConfiguration: { networkMode: 'PUBLIC' },
});
```

`src/bedrock-agent/Dockerfile`:

```dockerfile
FROM public.ecr.aws/lambda/python:3.12
RUN pip install strands-agents boto3
COPY agent.py .
CMD ["agent.handler"]
```

### Step 7 — Import `base-infra` resources and write SSM outputs

Import the artifacts S3 bucket and KMS key ARN the same way `tak-infra`/`utils-infra` already do via `cloudformation-imports.ts`. Write the resulting IDs to SSM with `ssm.StringParameter` instead of the script's `write_ssm`:

```typescript
new ssm.StringParameter(this, 'KbIdParam', {
  parameterName: `${ssmPrefix}/bedrock/${kbName}/kb-id`,
  stringValue: kb.attrKnowledgeBaseId,
});
new ssm.StringParameter(this, 'AgentRuntimeIdParam', {
  parameterName: `${ssmPrefix}/bedrock/${kbName}/agent-runtime-id`,
  stringValue: runtime.attrAgentRuntimeId,
});
// Keep agent-id / agent-alias-id parameters during the transition for rollback reference
```

### Step 8 — Update the ATAK bot / TAK-GPT plugin caller

The bot currently invokes the agent via `bedrock-agent-runtime`:

```python
# Current
client = boto3.client("bedrock-agent-runtime")
response = client.invoke_agent(
    agentId=agent_id,
    agentAliasId=alias_id,
    sessionId=session_id,
    inputText=user_message
)
```

This changes to `bedrock-agentcore-runtime`:

```python
# New
client = boto3.client("bedrock-agentcore-runtime")
response = client.invoke_agent_runtime(
    agentRuntimeId=agent_runtime_id,
    sessionId=session_id,
    payload={"inputText": user_message}
)
```

The `RETURN_CONTROL` response shape also changes slightly — parse the response stream for `returnControl` events and handle them the same way as today.

### Step 9 — Retire the GeoJSON/ArcGIS constructs and outputs in `tak-infra`

Once the Lambdas and Agent live in `bedrock-infra`, remove `BedrockGeoJsonLambda`/`BedrockArcGisLambda` and their `CfnOutput`s from `tak-infra-stack.ts`, and delete `lib/constructs/bedrock-geojson-lambda.ts` / `bedrock-arcgis-lambda.ts` from `tak-infra` (they've moved, not duplicated).

### Step 10 — Test in Dev-Test

Deploy `bedrock-infra` against the `Dev` environment:

```bash
npm run deploy:dev --context kbName=nema-cdem --context agentName="RELAY Dev"
```

Verify:
- AOSS collection and vector index reach ACTIVE state
- Knowledge base and data source are created, initial sync completes
- Agent runtime reaches ACTIVE state
- KB retrieval works (ask a doctrine question)
- `live-data` tools work (ask about road delays or earthquakes)
- `geocode` tools work (ask for a place by name)
- `RETURN_CONTROL` works — a marker request returns the correct tool call payload to the ATAK client
- SSM parameters are written under the expected prefix

### Step 11 — Migrate Prod and decommission Classic agents

Once Dev-Test is stable, repeat for Prod. The Classic agents can be left running in parallel during the transition. Decommission them, delete `scripts/bedrock/` from `tak-infra`, and remove the now-unused Classic-agent SSM parameters once the bot config is fully switched to the new runtime IDs.

---

## Files to Create / Modify

| File | Repo | Action |
|---|---|---|
| `bin/bedrock-infra.ts`, `lib/bedrock-infra-stack.ts`, `cdk.json`, `package.json` | `bedrock-infra` (new) | New — repo scaffold |
| `lib/constructs/aoss-collection.ts` | `bedrock-infra` (new) | New — AOSS collection, policies, vector index |
| `lib/constructs/knowledge-base.ts` | `bedrock-infra` (new) | New — Bedrock Knowledge Base + data source |
| `lib/constructs/agent-runtime.ts` | `bedrock-infra` (new) | New — AgentCore Runtime, IAM roles, `DockerImageAsset` |
| `lib/constructs/bedrock-geojson-lambda.ts`, `bedrock-arcgis-lambda.ts` | `bedrock-infra` (new) | Moved from `tak-infra` |
| `src/bedrock-agent/agent.py`, `Dockerfile`, `requirements.txt` | `bedrock-infra` (new) | New — Strands agent application |
| `nz_rag_responder.txt`, `nzdf_rag_responder.txt`, `cot-types.txt`, etc. | `bedrock-infra` (new) | Moved from `tak-infra/scripts/bedrock/` |
| `lib/tak-infra-stack.ts` | `tak-infra` | Modify — remove `BedrockGeoJsonLambda`/`BedrockArcGisLambda` instantiation and outputs |
| `lib/constructs/bedrock-geojson-lambda.ts`, `bedrock-arcgis-lambda.ts` | `tak-infra` | Delete — moved to `bedrock-infra` |
| `scripts/bedrock/` (entire directory) | `tak-infra` | Delete once `bedrock-infra` is stable in Prod |
| TAK-GPT plugin caller (`BedrockChatManager.java` or equivalent bot config loader) | `tak-infra` | Modify — switch to `bedrock-agentcore-runtime` client |

---

## Reference

- [AgentCore Harness vs Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/harness-vs-runtime.html)
- [Bedrock Agents Classic maintenance mode](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html)
- [Strands Agents SDK](https://strandsagents.com)
- [AgentCore Runtime boto3 client](https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/bedrock-agentcore-runtime.html)
- [AgentCore Starter Toolkit](https://github.com/aws/bedrock-agentcore-starter-toolkit)
- [Build AI agents with Amazon Bedrock AgentCore using AWS CloudFormation](https://aws.amazon.com/blogs/machine-learning/build-ai-agents-with-amazon-bedrock-agentcore-using-aws-cloudformation/)
- [Using CloudFormation to create Amazon OpenSearch Serverless collections](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-cfn.html)
