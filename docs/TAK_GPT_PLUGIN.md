# TAK-GPT Plugin Integration

This implementation integrates the [tak-gpt plugin](https://github.com/raytheonbbn/tak-gpt) into the TAK Server Docker image, enabling AI-powered chat capabilities within TAK.

## Architecture

The plugin is built during Docker image creation and configured at container startup:

1. **Build Time**: Plugin is compiled from source and bundled into the Docker image at `/opt/tak/lib/tak-gpt-all.jar`
2. **Runtime**: Configuration files are downloaded from S3 at container startup to `/opt/tak/conf/plugins/`

## Implementation Details

### Docker Build Process

The Dockerfile includes:

1. **Dependency Extraction**: Extracts TAK API JARs from the distribution ZIP
2. **Plugin Compilation**: Builds plugin from `plugins/tak-gpt/` with Gradle
3. **JAR Installation**: Places compiled JAR in `/opt/tak/lib/`

### Runtime Configuration

At container startup (`start-tak.sh`):

1. Downloads plugin configuration from S3 config bucket (from BaseInfra stack)
2. Places files in `/opt/tak/conf/plugins/`:
   - `tak.server.plugins.TAKChatBotBase.yaml` - Plugin configuration
   - `nz_rag_responder.txt` - RAG prompt instructions (optional)

### Plugin Discovery

TAK Server automatically discovers plugins in `/opt/tak/lib/`. The `<plugins/>` element in CoreConfig.xml must remain empty per XSD schema requirements.

## Configuration

### AWS Bedrock (Recommended)

Uses IAM credentials from the ECS task role. No API keys required. Supports tool calling for creating TAK map markers across all compatible Bedrock models via the Converse API.

**Basic Configuration:**

```yaml
bots:
  - modelType: "bedrock"
    region: "ap-southeast-2"  # Sydney region for New Zealand deployments
    modelName: "au.anthropic.claude-sonnet-4-6"  # Inference profile for Claude Sonnet 4.6
    systemPromptFilePath: /opt/tak/conf/plugins/nz_rag_responder.txt
    botName: "TAK-GPT"
    latitude: -41.2865
    longitude: 174.7762
    groups: ["__ANON__"]
    groupName: "Purple"
    role: "HQ"
    cotType: "a-f-G-U-C-I"
```

**Knowledge Base Configuration (RAG):**

To use Bedrock Knowledge Bases for retrieval-augmented generation (RAG) from PDF documents in S3:

```yaml
bots:
  - modelType: "bedrock"
    region: "ap-southeast-2"
    modelName: "au.anthropic.claude-sonnet-4-6"
    knowledgeBaseId: "ABCD1234"  # Your Bedrock Knowledge Base ID
    systemPromptFilePath: /opt/tak/conf/plugins/nz_rag_responder.txt
    botName: "NZ First Responder Chatbot"
    latitude: -41.2865
    longitude: 174.7762
    groups: ["Regions - All of New Zealand"]
    groupName: "Purple"
    role: "HQ"
    cotType: "a-f-G-U-C-I"
```

**Note:** Standalone Knowledge Base mode (using `RetrieveAndGenerate` API) does NOT support tool calling.

**Bedrock Agent Configuration (RAG + Tool Calling + Live Data):**

For Knowledge Base retrieval, tool calling (map markers), and live GeoJSON data queries, use Bedrock Agents:

```yaml
bots:
  - modelType: "bedrock"
    region: "us-west-2"
    agentId: "AGENT123"          # From SSM: /tak/<env>/bedrock/<kb-name>/agent-id
    agentAliasId: "TSTALIASID"   # TSTALIASID always uses DRAFT (latest). Use a real alias ID for a stable production snapshot.
    botName: "NZ Field Assistant"
    latitude: -41.2784
    longitude: 174.7767
    groups: ["Regions - All of New Zealand"]
    groupName: "Purple"
    role: "HQ"
    cotType: "a-f-G-I-G"
```

**Note:** In agent mode, `modelName` and `systemPromptFilePath` are ignored — the agent's instruction (set via `setup-bedrock-agent.py`) controls behaviour.

**Setting up a Bedrock Agent:**

Use the provided setup script to create the OpenSearch Serverless collection, Knowledge Base, and Agent:

```bash
python3 scripts/bedrock/setup-bedrock-agent.py \
  --environment Demo \
  --kb-name nema-cdem \
  --agent-name "NEMA CDEM Bot" \
  --system-prompt-file scripts/bedrock/nz_rag_responder.txt
```

See [scripts/bedrock/README.md](../scripts/bedrock/README.md) for full details including document sync, KML/KMZ conversion, and re-running.

**Live GeoJSON Data Sources:**

The agent has access to live data via the `query_geojson` Lambda action group (deployed by CDK):

- Road delays/closures: `https://www.journeys.nzta.govt.nz/assets/map-data-cache/delays.json`
- Variable message signs: `https://www.journeys.nzta.govt.nz/assets/map-data-cache/vms.json`
- Earthquakes: `https://api.geonet.org.nz/quake?MMI=3`
- Volcano alert levels: `https://api.geonet.org.nz/volcano/val`

Proximity queries ("near me") use the user's TAK location automatically when available.

**How Bedrock Agents Work:**

1. Create a Bedrock Agent in AWS Console
2. Attach Knowledge Base(s) to the agent for RAG
3. Define Action Groups (Lambda functions) for tool calling
4. Agent orchestration (ReAct loop) decides whether to:
   - Retrieve from Knowledge Base (doctrine questions)
   - Call Action Group tools (live data queries)
   - Do both and synthesize the answer
5. Each bot can have its own agent with different knowledge bases and action groups

**Configuration Priority:**
- If `agentId` is set → Uses Bedrock Agent (supports RAG + tools)
- Else if `knowledgeBaseId` is set → Uses RetrieveAndGenerate API (RAG only, no tools)
- Else → Uses Converse API (tools only, no RAG)

**Tool Calling Support:**

The bot can create map markers when asked. Example queries:
- "Create a hostile ground marker with callsign Alpha at latitude 42.382 and longitude -71.075"
- "Create a map marker of type a-h-G with callsign Bravo at lat 42.382 and lon -71.075"
- "Add a friendly air marker called Charlie at 42.382, -71.075"

**Regional Considerations:**
- **New Zealand Deployments**: Use Sydney region (`ap-southeast-2`) as Auckland (`ap-southeast-6`) does not support Bedrock
- **Australia-Specific Inference Profile**: `au.anthropic.claude-sonnet-4-6` provides lowest latency for ANZ region
- **US Deployments**: Use `us-west-2` with inference profile `us.anthropic.claude-sonnet-4-6`

**Supported Bedrock Models:**

*Inference Profiles (recommended):*
- `au.anthropic.claude-sonnet-4-6` - Claude Sonnet 4.6 (Australia/NZ)
- `us.anthropic.claude-sonnet-4-6` - Claude Sonnet 4.6 (US)
- `eu.anthropic.claude-sonnet-4-6` - Claude Sonnet 4.6 (Europe)
- `us.anthropic.claude-3-5-sonnet-20241022-v2:0` - Claude 3.5 Sonnet v2
- `us.anthropic.claude-3-5-haiku-20241022-v1:0` - Claude 3.5 Haiku

*Legacy Direct Model IDs (older models, use inference profiles instead):*
- `anthropic.claude-3-5-haiku-20241022-v1:0` - Claude 3.5 Haiku
- `anthropic.claude-3-5-sonnet-20240620-v1:0` - Claude 3.5 Sonnet v1
- `anthropic.claude-3-sonnet-20240229-v1:0` - Claude 3 Sonnet
- `anthropic.claude-3-haiku-20240307-v1:0` - Claude 3 Haiku

**Note:** Newer Claude models (Sonnet 4.x) require inference profiles. Use the test script to verify availability in your region.

**IAM Permissions** (automatically added by CDK):
```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream",
    "bedrock:Retrieve",
    "bedrock:RetrieveAndGenerate",
    "bedrock:InvokeAgent"
  ],
  "Resource": [
    "arn:aws:bedrock:*::foundation-model/*",
    "arn:aws:bedrock:*:ACCOUNT_ID:inference-profile/*",
    "arn:aws:bedrock:*:ACCOUNT_ID:knowledge-base/*",
    "arn:aws:bedrock:*:ACCOUNT_ID:agent/*",
    "arn:aws:bedrock:*:ACCOUNT_ID:agent-alias/*/*"
  ]
}
```

**Testing Model Availability:**

Use the provided test script to verify model availability in your region:

```bash
# Test inference profile in Sydney region
./scripts/takserver/test-bedrock-inference-profile.py \
  --region ap-southeast-2 \
  --model au.anthropic.claude-sonnet-4-6

# Test direct model ID in US West 2
./scripts/takserver/test-bedrock-inference-profile.py \
  --region us-west-2 \
  --model anthropic.claude-3-5-haiku-20241022-v1:0

# List all available inference profiles
aws bedrock list-inference-profiles --region ap-southeast-2
```

### Other Providers

**OpenAI:**
```yaml
bots:
  - modelType: "openai"
    apiKey: "YOUR_API_KEY"
    modelName: "gpt-4"
    systemPromptFilePath: /opt/tak/conf/plugins/nz_rag_responder.txt
    botName: "TAK-GPT"
    latitude: -41.2865
    longitude: 174.7762
    groups: ["__ANON__"]
```

**Anthropic:**
```yaml
bots:
  - modelType: "anthropic"
    apiKey: "YOUR_API_KEY"
    modelName: "claude-3-opus-20240229"
    systemPromptFilePath: /opt/tak/conf/plugins/nz_rag_responder.txt
    botName: "TAK-GPT"
    latitude: -41.2865
    longitude: 174.7762
    groups: ["__ANON__"]
```

**Ollama:**
```yaml
bots:
  - modelType: "ollama"
    endpoint: "http://your-ollama-server:11434"
    modelName: "llama3.2"
    systemPromptFilePath: /opt/tak/conf/plugins/nz_rag_responder.txt
    botName: "TAK-GPT"
    latitude: -41.2865
    longitude: 174.7762
    groups: ["__ANON__"]
```

### Bot Appearance Configuration

Customize how the bot appears on the TAK map:

- **`botName`**: Display name in chat (e.g., "TAK-GPT", "AI Assistant")
- **`latitude`/`longitude`**: Bot's map position (e.g., `-41.2865, 174.7762` for Wellington, NZ)
- **`groups`**: TAK groups bot can interact with (e.g., `["__ANON__"]` for all users)
- **`groupName`**: Team/group affiliation shown on map (e.g., "Purple", "Red", "Blue")
- **`role`**: Operational role displayed (e.g., "HQ", "Team Member", "Support")
- **`cotType`**: CoT type defining the map icon:
  - `a-f-G-I-G` - Friendly government installation (recommended for admin/HQ bots)
  - `a-f-G-U-H` - Friendly C2 headquarters component
  - `a-f-G-U-C-I` - Friendly ground infantry unit
  - `a-f-G-E-S` - Friendly ground equipment (static)
  - See [MIL-STD-2525](https://www.spatialillusions.com/unitgenerator/) for more CoT types

**Example Configurations:**

```yaml
# HQ Command Bot (Government/Admin)
botName: "NZ Field Assistant"
groupName: "Purple"
role: "HQ"
cotType: "a-f-G-I-G"

# Field Support Bot
botName: "Field AI"
groupName: "Blue"
role: "Support"
cotType: "a-f-G-E-S"

# Aerial Reconnaissance Bot
botName: "Recon AI"
groupName: "Red"
role: "ISR"
cotType: "a-f-A"
```

## Deployment

### 1. Upload Plugin Configuration to S3

Use the provided script:

```bash
./scripts/takserver/upload-plugin-config.sh <Environment> <yaml-config> <rag-prompt>

# Example:
./scripts/takserver/upload-plugin-config.sh Demo \
  tak.server.plugins.TAKChatBotBase.yaml \
  scripts/bedrock/nz_rag_responder.txt
```

Or manually:

```bash
# Get bucket name
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name TAK-<ENV>-BaseInfra \
  --query 'Stacks[0].Outputs[?OutputKey==`S3EnvConfigArnOutput`].OutputValue' \
  --output text | sed 's|arn:aws:s3:::||')

# Upload files
aws s3 cp tak.server.plugins.TAKChatBotBase.yaml \
  s3://${BUCKET_NAME}/takserver-plugins/tak-gpt/

aws s3 cp scripts/bedrock/nz_rag_responder.txt \
  s3://${BUCKET_NAME}/takserver-plugins/tak-gpt/
```

### 2. Deploy Infrastructure

```bash
npm run deploy:dev   # Development
npm run deploy:prod  # Production
```

### 3. Restart TAK Server

```bash
aws ecs update-service \
  --cluster TAK-<ENV>-BaseInfra-EcsCluster \
  --service TAK-<ENV>-TakInfra-TakServer \
  --force-new-deployment
```

## Verification

### Check Plugin Loading

View plugin logs:

```bash
# Get task ID
TASK_ID=$(aws ecs list-tasks \
  --cluster TAK-<ENV>-BaseInfra-EcsCluster \
  --service-name TAK-<ENV>-TakInfra-TakServer \
  --query 'taskArns[0]' --output text | cut -d'/' -f3)

# View logs
aws logs tail /aws/ecs/TAK-<ENV>-TakInfra-takserver \
  --follow --filter-pattern "TAKChatBotBase"
```

Expected log output:
```
plugin class name: tak.server.plugins.TAKChatBotBase
Set isEnabled for plugin class tak.server.plugins.TAKChatBotBase to true
Registered sender-receiver plugin instance: tak.server.plugins.TAKChatBotBase
Starting up TAK GPT Plugin
```

### Verify Configuration Download

SSH into container:

```bash
aws ecs execute-command \
  --cluster TAK-<ENV>-BaseInfra-EcsCluster \
  --task $TASK_ID \
  --container TakServer \
  --interactive \
  --command "/bin/bash"

# Check files
ls -la /opt/tak/conf/plugins/
cat /opt/tak/conf/plugins/tak.server.plugins.TAKChatBotBase.yaml
```

## Troubleshooting

### Plugin Not Loading

1. **Check JAR exists:**
   ```bash
   ls -la /opt/tak/lib/tak-gpt-all.jar
   ```

2. **Verify configuration downloaded:**
   ```bash
   ls -la /opt/tak/conf/plugins/
   ```

3. **Check S3 permissions:**
   - Task role needs `s3:GetObject` on config bucket
   - Verify: `aws s3 ls s3://<bucket>/takserver-plugins/tak-gpt/`

### Bedrock API Errors

Error: `messages.0.content.0.type: Field required`

**Solution:** Update the BedrockChatManager to include `type` field in content objects. This is fixed in the latest version. Rebuild and redeploy:
```bash
npm run deploy:dev  # or deploy:prod
```

### Build Failures

1. **Check Gradle build logs** in Docker build output
2. **Verify source exists:** `ls plugins/tak-gpt/`
3. **Check TAK dependencies:** Ensure `extract-tak-deps.sh` ran successfully

## Maintenance

### Testing Bedrock Model Availability

Before deploying with a new model, test its availability:

```bash
# Test model in your deployment region
./scripts/takserver/test-bedrock-inference-profile.py \
  --region ap-southeast-2 \
  --model au.anthropic.claude-sonnet-4-6

# List all available models and inference profiles
aws bedrock list-foundation-models --region ap-southeast-2
aws bedrock list-inference-profiles --region ap-southeast-2
```

### Updating Plugin Code

1. Modify source in `plugins/tak-gpt/`
2. Rebuild Docker image
3. Deploy to ECS

### Updating Configuration

Upload new config to S3 and restart service:

```bash
./scripts/takserver/upload-plugin-config.sh <ENV> <yaml> <prompt>

aws ecs update-service \
  --cluster TAK-<ENV>-BaseInfra-EcsCluster \
  --service TAK-<ENV>-TakInfra-TakServer \
  --force-new-deployment
```

## Security Considerations

- **API Keys**: Store in AWS Secrets Manager, not in S3 config files
- **IAM Permissions**: Use least-privilege access for S3 and Bedrock
- **Audit**: CloudTrail logs all Bedrock API calls
- **Code Review**: Review tak-gpt source before deployment

## Files Modified

### New Files
- `plugins/tak-gpt/` - Plugin source code (submodule)
- `plugins/tak-gpt/lib/src/main/java/tak/server/plugins/agent/BedrockChatManager.java` - AWS Bedrock client (Converse, KB, Agent + RETURN_CONTROL)
- `plugins/tak-gpt/lib/src/main/resources/plugin.version` - Version file
- `docker/tak-server/plugin-build.gradle` - Gradle build configuration
- `docker-container/scripts/download-plugin-config.sh` - S3 download script
- `scripts/takserver/upload-plugin-config.sh` - S3 upload helper
- `scripts/takserver/test-bedrock-inference-profile.py` - Bedrock model testing script
- `scripts/bedrock/setup-bedrock-agent.py` - Idempotent setup for AOSS, Knowledge Base, and Agent
- `scripts/bedrock/README.md` - Bedrock agent setup and document sync guide
- `lambda/geojson-query/index.py` - Lambda handler for live GeoJSON queries (proximity + text filter)
- `lib/constructs/bedrock-geojson-lambda.ts` - CDK construct for the GeoJSON query Lambda

### Modified Files
- `docker/tak-server/Dockerfile.tak-nz` - Plugin build steps
- `docker/tak-server/Dockerfile.generic` - Plugin build steps
- `docker-container/scripts/start-tak.sh` - Plugin config download
- `lib/constructs/tak-server.ts` - IAM permissions for Bedrock and S3
- `plugins/tak-gpt/lib/src/main/java/tak/server/plugins/TAKChatBotBase.java` - Bedrock support, configurable bot appearance
- `plugins/tak-gpt/lib/src/main/java/tak/server/plugins/TAKBOTPresenceBroadcaster.java` - Configurable groupName, role, cotType

## References

- [tak-gpt GitHub Repository](https://github.com/raytheonbbn/tak-gpt)
- [AWS Bedrock Documentation](https://docs.aws.amazon.com/bedrock/)
- [TAK Server Plugin Documentation](https://tak.gov/)

## Future Development: Live TAK Situational Awareness Queries

A natural extension of the agent's tool-calling capability would be allowing it to query live CoT data from the TAK server — enabling questions like "what units are near me?" or "is there air support in the area?".

### Approach

The TAK plugin SDK's `PredicateDataFeed` provides a group-filtered stream of all CoT events transiting the server — TAK clients (ATAK/iTAK/WinTAK/InReach), ADS-B aircraft, AIS vessels, and any other data feed. This stream would feed a bounded in-memory cache (keyed by UID), which a `query_tak_contacts` RETURN_CONTROL tool would query on demand.

Cache characteristics:
- Keyed by UID — frequent updates (e.g. ADS-B every 20s) overwrite the same entry, not add new ones
- TTL of 30 minutes minimum to accommodate slow check-in devices (InReach: ~15 min interval)
- Memory footprint is negligible (~250 bytes/entry; 1000 entries ≈ 250 KB)
- Group visibility enforced by the server before delivery to the feed

### CoT Metadata Available for Reasoning

CoT `<detail>` blocks carry structured metadata beyond position and type that meaningfully improves the agent's ability to reason about assets:

- `<contact callsign="..."/>` — human-readable name
- `<__group name="..." role="..."/>` — team affiliation and role (e.g. NZ-Police-Air, ISR)
- `<usericon iconsetpath="..."/>` — icon set, often encodes agency (e.g. NZ Police iconsets vs. generic ADS-B)
- `<remarks>` — free text unit description
- Custom extension elements — e.g. vessel MMSI, aircraft registration, agency-specific fields
- **Hashtags** — CoTs tagged with `#sar`, `#nzdf`, `#fenz` etc. (used in ATAK for filtering) provide a direct, operator-controlled classification signal

This metadata allows the agent to distinguish `EAGLE-1, type a-f-A, group NZ-Police-Air, role ISR, tags #nzpol` from `ZK-HVK, type a-f-A, group ADS-B-Feed, tags none`. The tool should extract and pass all available fields; the agent instruction defines how to interpret them operationally. Metadata quality is inconsistent across feeds — the agent instruction should tell the agent to caveat responses when metadata is sparse.

### Division of Labour

The right split between tool and prompt:

- **Tool (Java)**: proximity filter, CoT type filter, tag filter, group visibility filter, TTL filter, result cap, metadata extraction — returns a structured list with all available fields
- **Prompt (agent instruction)**: operational reasoning over that list — what "nearest available rescue asset" means, how to weight recency vs. distance, when to caveat staleness

This keeps the tool generic and mechanical (deployable without prompt changes) while keeping operational reasoning in the prompt where it can be updated without redeploying code.

### Why This Needs Careful Design

The fundamental challenge is not technical — it is **information relevance**. A TAK server accumulates CoT from many sources simultaneously: personnel, vehicles, aircraft, vessels, infrastructure markers, sensor feeds. Exposing this raw to an AI agent creates several problems:

- **Context window pollution**: Returning hundreds of nearby CoTs degrades reasoning quality. The tool must pre-filter aggressively and cap results before returning to the agent.
- **Semantic gap without metadata**: Without tags and group/role fields, the agent cannot distinguish a police marine asset from a harbour tug. With them, it can — but only if the CoT was tagged consistently by operators.
- **Group visibility**: The bot may be in broader groups than the asking user. Results must be filtered to the intersection of the user's groups (available in `TAKContext`) and the asset's groups to avoid leaking assets across organisational boundaries.
- **Inconsistent metadata quality**: Some feeds populate rich detail; others send only position and type. The tool must pass through whatever is present without assuming completeness.

### Design Principles for Implementation

Any implementation should follow these constraints:

1. Mandatory proximity filter — never return all contacts, always require a radius
2. Hard cap on results returned to the agent (e.g. top 10–20 nearest)
3. Filter by CoT type relevant to the query (e.g. `a-*` for SA, exclude chat/pings/infrastructure)
4. Optional tag filter — allow the agent to request only assets matching specific hashtags (e.g. `#sar`)
5. Surface `lastSeen` timestamp in every result so the agent can qualify freshness
6. Apply user group intersection filter before returning results
7. Consider separate tools for different asset classes (personnel vs. air vs. maritime) rather than one generic query, so the agent can be precise about what it is asking for
