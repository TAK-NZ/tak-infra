#!/usr/bin/env python3
"""
Setup a Bedrock Agent with an attached Knowledge Base sourced from an S3 prefix.
The knowledge base (S3 Vectors index, IAM role, data source) is created by the TakInfra CDK stack, not by
this script. Deploy the stack with the knowledge base name in `bedrock.knowledgeBases` first. The script
then syncs the knowledge base if it has never been ingested, and creates or updates the agent, its action
groups and alias.

Usage:
  python3 setup-bedrock-agent.py \
    --environment Prod \
    --kb-name nema-cdem \
    --agent-name "NEMA CDEM Bot" \
    --system-prompt "You are a helpful assistant for NEMA and CDEM operations." \
    [--ssm-prefix /tak/prod] \
    [--profile my-aws-profile] \
    [--region ap-southeast-2]

The BaseInfra stack name is derived as TAK-<environment>-BaseInfra.
"""

import argparse
import json
import re
import sys
import time
import boto3
from botocore.exceptions import ClientError
from pathlib import Path

# Claude model used by the agent. Chosen by benchmark, see docs/TAK_GPT_MODEL_BENCHMARK.md.
# AU/NZ regions use the Australia-resident inference profile; US regions use the US profile.
AGENT_MODEL_NAME = "claude-sonnet-5-5"


def default_model_id(region):
    prefix = "us" if region.startswith("us-") else "au"
    return f"{prefix}.anthropic.{AGENT_MODEL_NAME}"


# Orchestration prompt template, pinned (promptCreationMode OVERRIDDEN) instead of left to
# Bedrock's defaults. Reason: with default prompts, Bedrock adds
#   additionalModelRequestFields = {"thinking": {"type": "enabled", "budget_tokens": 1024}}
# when preparing the agent. Claude Sonnet 5.5 rejects that format ("thinking.type.enabled is not
# supported for this model"), so every chat fails. The template below is the same text the agents
# used before; the only difference is that no thinking field is sent.
ORCHESTRATION_TEMPLATE_FILE = Path(__file__).parent / "orchestration-prompt-template.txt"


def prompt_override_config():
    template = ORCHESTRATION_TEMPLATE_FILE.read_text(encoding="utf-8")
    return {
        "promptConfigurations": [
            {"promptType": "PRE_PROCESSING", "promptCreationMode": "DEFAULT"},
            {"promptType": "MEMORY_SUMMARIZATION", "promptCreationMode": "DEFAULT"},
            {
                "promptType": "ORCHESTRATION",
                "promptCreationMode": "OVERRIDDEN",
                "promptState": "ENABLED",
                "basePromptTemplate": template,
                "inferenceConfiguration": {"temperature": 1.0, "stopSequences": ["</answer>"]},
                "parserMode": "DEFAULT",
            },
            {"promptType": "KNOWLEDGE_BASE_RESPONSE_GENERATION", "promptCreationMode": "DEFAULT"},
            {"promptType": "POST_PROCESSING", "promptCreationMode": "DEFAULT"},
        ]
    }


def get_stack_outputs(cf_client, stack_name):
    resp = cf_client.describe_stacks(StackName=stack_name)
    return {o["OutputKey"]: o["OutputValue"] for o in resp["Stacks"][0].get("Outputs", [])}


def get_artifacts_bucket(outputs):
    bucket_name = None
    kms_key_arn = None
    for key, value in outputs.items():
        if key in ("S3TAKImagesArnOutput", "AppImagesBucketOutput"):
            bucket_name = value.split(":::")[-1] if ":::" in value else value
        if key == "KmsKeyArnOutput":
            kms_key_arn = value
    if not bucket_name:
        raise ValueError("Could not find artifacts bucket output in stack")
    return bucket_name, kms_key_arn


def get_lambda_arn(cf_client, tak_infra_stack_name, key_fragment):
    """Read a Lambda ARN from the TakInfra stack outputs by key fragment."""
    try:
        outputs = get_stack_outputs(cf_client, tak_infra_stack_name)
        for key, value in outputs.items():
            if key_fragment in key:
                return value
    except ClientError:
        pass
    return None


def get_account_id(sts_client):
    return sts_client.get_caller_identity()["Account"]


def ensure_agent_iam_role(iam_client, role_name, region, account_id):
    trust = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "bedrock.amazonaws.com"},
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {"aws:SourceAccount": account_id},
                "ArnLike": {"aws:SourceArn": f"arn:aws:bedrock:{region}:{account_id}:agent/*"}
            }
        }]
    }
    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
                "Resource": "*"
            },
            {
                "Effect": "Allow",
                "Action": "bedrock:GetInferenceProfile",
                "Resource": [
                    f"arn:aws:bedrock:{region}::foundation-model/*",
                    f"arn:aws:bedrock:{region}:{account_id}:inference-profile/*"
                ]
            },
            {
                "Effect": "Allow",
                "Action": ["bedrock:Retrieve", "bedrock:RetrieveAndGenerate"],
                "Resource": f"arn:aws:bedrock:{region}:{account_id}:knowledge-base/*"
            }
        ]
    }
    existing = True
    try:
        role = iam_client.get_role(RoleName=role_name)["Role"]
        print(f"  IAM role already exists: {role_name}")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        existing = False
        role = iam_client.create_role(
            RoleName=role_name,
            AssumeRolePolicyDocument=json.dumps(trust),
            Description="Bedrock Agent execution role"
        )["Role"]
        print(f"  Created IAM role: {role_name}")
    iam_client.put_role_policy(
        RoleName=role_name,
        PolicyName="BedrockAgentPolicy",
        PolicyDocument=json.dumps(policy)
    )
    time.sleep(15)  # IAM propagation
    return role["Arn"]


def knowledge_base_output_suffix(kb_name):
    """`nema-cdem` -> `NemaCdem`. Must match knowledgeBaseOutputSuffix() in lib/tak-infra-stack.ts."""
    return "".join(part[:1].upper() + part[1:].lower() for part in re.split(r"[^a-zA-Z0-9]+", kb_name) if part)
def get_knowledge_base_ids(cf_client, tak_infra_stack_name, kb_name):
    """Knowledge base and data source IDs from the TakInfra stack outputs.
    The knowledge base itself (S3 Vectors index, role, data source) is created by the stack, see
    lib/constructs/bedrock-knowledge-base.ts. Add `kb_name` to `bedrock.knowledgeBases` in cdk.json
    (or --context bedrockKnowledgeBases=...) and deploy first."""
    suffix = knowledge_base_output_suffix(kb_name)
    outputs = get_stack_outputs(cf_client, tak_infra_stack_name)
    kb_key, ds_key = f"BedrockKb{suffix}Id", f"BedrockKb{suffix}DataSourceId"
    if kb_key not in outputs or ds_key not in outputs:
        raise SystemExit(
            f"Stack {tak_infra_stack_name} has no output {kb_key}. Add '{kb_name}' to bedrock.knowledgeBases "
            f"(cdk.json, or --context bedrockKnowledgeBases) and deploy the stack, then run this script again."
        )
    return outputs[kb_key], outputs[ds_key]
def ensure_knowledge_base_synced(bedrock_agent_client, kb_id, ds_id, timeout_s=2700):
    """Make sure the knowledge base has ingested its documents before an agent uses it.
    Starts an ingestion job only if the data source has never completed one and none is running.
    Later document changes still need a manual sync, see README.md."""
    jobs = bedrock_agent_client.list_ingestion_jobs(knowledgeBaseId=kb_id, dataSourceId=ds_id)["ingestionJobSummaries"]
    if any(j["status"] == "COMPLETE" for j in jobs):
        print("  Knowledge base already synced")
        return
    running = [j for j in jobs if j["status"] in ("STARTING", "IN_PROGRESS")]
    if running:
        job_id = running[0]["ingestionJobId"]
        print(f"  Ingestion job already running: {job_id}")
    else:
        job_id = bedrock_agent_client.start_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id)["ingestionJob"]["ingestionJobId"]
        print(f"  Started initial ingestion job: {job_id}")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        job = bedrock_agent_client.get_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id, ingestionJobId=job_id)["ingestionJob"]
        if job["status"] == "COMPLETE":
            stats = job.get("statistics", {})
            print(f"  Ingestion complete: {stats.get('numberOfNewDocumentsIndexed', 0)} documents indexed, {stats.get('numberOfDocumentsFailed', 0)} failed")
            return
        if job["status"] in ("FAILED", "STOPPED"):
            raise RuntimeError(f"Ingestion job {job_id} {job['status']}: {job.get('failureReasons')}")
        time.sleep(15)
    raise TimeoutError(f"Ingestion job {job_id} did not finish within {timeout_s // 60} minutes; run the script again once it has")
def detach_other_knowledge_bases(bedrock_agent_client, agent_id, keep_kb_id):
    """Each agent here has exactly one knowledge base. Detach any other (the old OpenSearch one)."""
    attached = bedrock_agent_client.list_agent_knowledge_bases(agentId=agent_id, agentVersion="DRAFT")["agentKnowledgeBaseSummaries"]
    detached = False
    for kb in attached:
        if kb["knowledgeBaseId"] != keep_kb_id:
            bedrock_agent_client.disassociate_agent_knowledge_base(agentId=agent_id, agentVersion="DRAFT", knowledgeBaseId=kb["knowledgeBaseId"])
            print(f"  Detached old knowledge base {kb['knowledgeBaseId']} from agent")
            detached = True
    return detached
GEOJSON_SOURCES = (
    "road delays/closures: https://www.journeys.nzta.govt.nz/assets/map-data-cache/delays.json ; "
    "variable message signs (live road messages): https://www.journeys.nzta.govt.nz/assets/map-data-cache/vms.json ; "
    "earthquakes: https://api.geonet.org.nz/quake?MMI=3 ; "
    "volcano alert levels: https://api.geonet.org.nz/volcano/val"
)

GEOJSON_FUNCTION_SCHEMA = {
    "functions": [{
        "name": "query_geojson",
        "description": (
            "Fetch live GeoJSON data from a URL and return matching features as plain text. "
            f"Known sources: {GEOJSON_SOURCES}. "
            "Pass lat/lon from the user's location prefix when available for proximity queries."
        ),
        "parameters": {
            "url": {"type": "string", "description": "GeoJSON endpoint URL", "required": True},
            "lat": {"type": "string", "description": "User latitude for proximity filter", "required": False},
            "lon": {"type": "string", "description": "User longitude for proximity filter", "required": False},
            "radius_km": {"type": "string", "description": "Search radius in km (default 50)", "required": False},
            "filter_text": {"type": "string", "description": "Keyword to filter features by property values", "required": False}
        }
    }]
}


GEOCODE_FUNCTION_SCHEMA = {
    "functions": [
        {
            "name": "find_place",
            "description": "Forward geocode a place name to coordinates. Use when the user mentions a location not found in the knowledge base. Pass the user's lat/lon when available for location-biased results.",
            "parameters": {
                "query": {"type": "string", "description": "Place name to search for", "required": True},
                "lat": {"type": "string", "description": "User latitude for location bias", "required": False},
                "lon": {"type": "string", "description": "User longitude for location bias", "required": False}
            }
        },
        {
            "name": "route_between",
            "description": (
                "Driving route between two New Zealand places. Returns the road distance, a traffic-aware drive time, "
                "the main roads used, and current NZTA delays and closures along the route. It automatically re-routes "
                "around full road closures and reports the detour. Use for any travel time, drive time, route or ETA "
                "question. Call it once per journey."
            ),
            "parameters": {
                "origin": {"type": "string", "description": "Start place name (for example 'Queenstown'), or 'lat,lon' such as the user's own position from the message prefix", "required": True},
                "destination": {"type": "string", "description": "End place name, or 'lat,lon'", "required": True}
            }
        },
        {
            "name": "reverse_geocode",
            "description": "Reverse geocode coordinates to a street address. Use when the user asks 'Where am I?' or similar and has a location in their message prefix.",
            "parameters": {
                "lat": {"type": "string", "description": "Latitude", "required": True},
                "lon": {"type": "string", "description": "Longitude", "required": True}
            }
        }
    ]
}


MARKER_FUNCTION_SCHEMA = {
    "functions": [{
        "name": "create_tak_map_marker",
        "description": "Create a map marker in TAK at a specified location.",
        "parameters": {
            "type": {"type": "string", "description": "CoT type, e.g. a-f-G", "required": True},
            "callsign": {"type": "string", "description": "Callsign/label for the marker", "required": True},
            "lat": {"type": "string", "description": "Latitude", "required": True},
            "lon": {"type": "string", "description": "Longitude", "required": True},
            "iconsetpath": {"type": "string", "description": "Optional custom icon in format '<uuid>/<folder>/<icon-name>.png'. Omit for default MIL-STD-2525B icon.", "required": False}
        }
    }]
}


def _ensure_marker_action_group(bedrock_agent_client, agent_id):
    action_group_name = "tak-tools"
    existing = bedrock_agent_client.list_agent_action_groups(
        agentId=agent_id, agentVersion="DRAFT")["actionGroupSummaries"]
    existing_ag = next((ag for ag in existing if ag["actionGroupName"] == action_group_name), None)

    if existing_ag:
        bedrock_agent_client.update_agent_action_group(
            agentId=agent_id,
            agentVersion="DRAFT",
            actionGroupId=existing_ag["actionGroupId"],
            actionGroupName=action_group_name,
            actionGroupExecutor={"customControl": "RETURN_CONTROL"},
            functionSchema=MARKER_FUNCTION_SCHEMA
        )
        print(f"  Updated tak-tools action group")
    else:
        bedrock_agent_client.create_agent_action_group(
            agentId=agent_id,
            agentVersion="DRAFT",
            actionGroupName=action_group_name,
            actionGroupExecutor={"customControl": "RETURN_CONTROL"},
            functionSchema=MARKER_FUNCTION_SCHEMA
        )
        print(f"  Created tak-tools action group")


def _ensure_lambda_action_group(bedrock_agent_client, agent_id, action_group_name, lambda_arn, function_schema):
    existing = bedrock_agent_client.list_agent_action_groups(
        agentId=agent_id, agentVersion="DRAFT")["actionGroupSummaries"]
    existing_ag = next((ag for ag in existing if ag["actionGroupName"] == action_group_name), None)

    if existing_ag:
        bedrock_agent_client.update_agent_action_group(
            agentId=agent_id, agentVersion="DRAFT",
            actionGroupId=existing_ag["actionGroupId"],
            actionGroupName=action_group_name,
            actionGroupExecutor={"lambda": lambda_arn},
            functionSchema=function_schema
        )
        print(f"  Updated {action_group_name} action group")
    else:
        bedrock_agent_client.create_agent_action_group(
            agentId=agent_id, agentVersion="DRAFT",
            actionGroupName=action_group_name,
            actionGroupExecutor={"lambda": lambda_arn},
            functionSchema=function_schema
        )
        print(f"  Created {action_group_name} action group (Lambda: {lambda_arn})")


def ensure_agent(bedrock_agent_client, agent_name, role_arn, system_prompt, kb_id, region, model_id, geojson_lambda_arn=None, arcgis_lambda_arn=None):
    # Check if agent already exists by name
    sanitized_name = agent_name.replace(" ", "-")
    paginator = bedrock_agent_client.get_paginator("list_agents")
    for page in paginator.paginate():
        for agent in page["agentSummaries"]:
            if agent["agentName"] == sanitized_name:
                agent_id = agent["agentId"]
                print(f"  Agent already exists: {agent_name} ({agent_id})")
                # Always update instruction in case it changed
                bedrock_agent_client.update_agent(
                    agentId=agent_id,
                    agentName=sanitized_name,
                    agentResourceRoleArn=role_arn,
                    foundationModel=model_id,
                    instruction=system_prompt,
                    idleSessionTTLInSeconds=1800,
                    promptOverrideConfiguration=prompt_override_config()
                )
                print(f"  Updated agent instruction, model ({model_id}) and orchestration prompt")
                # Ensure KB is associated
                existing_kbs = bedrock_agent_client.list_agent_knowledge_bases(
                    agentId=agent_id, agentVersion="DRAFT")["agentKnowledgeBaseSummaries"]
                if not any(kb["knowledgeBaseId"] == kb_id for kb in existing_kbs):
                    bedrock_agent_client.associate_agent_knowledge_base(
                        agentId=agent_id, agentVersion="DRAFT", knowledgeBaseId=kb_id,
                        description=f"Knowledge base for {agent_name}")
                    print(f"  Attached knowledge base {kb_id} to agent")
                    bedrock_agent_client.prepare_agent(agentId=agent_id)
                    print(f"  Re-preparing agent...")
                    _wait_for_agent(bedrock_agent_client, agent_id, "PREPARED")
                detach_other_knowledge_bases(bedrock_agent_client, agent_id, kb_id)
                _ensure_marker_action_group(bedrock_agent_client, agent_id)
                if geojson_lambda_arn:
                    _ensure_lambda_action_group(bedrock_agent_client, agent_id, "live-data", geojson_lambda_arn, GEOJSON_FUNCTION_SCHEMA)
                if arcgis_lambda_arn:
                    _ensure_lambda_action_group(bedrock_agent_client, agent_id, "geocode", arcgis_lambda_arn, GEOCODE_FUNCTION_SCHEMA)
                bedrock_agent_client.prepare_agent(agentId=agent_id)
                print(f"  Re-preparing agent...")
                _wait_for_agent(bedrock_agent_client, agent_id, "PREPARED")
                return agent_id

    resp = bedrock_agent_client.create_agent(
        agentName=sanitized_name,
        agentResourceRoleArn=role_arn,
        foundationModel=model_id,
        instruction=system_prompt,
        idleSessionTTLInSeconds=1800,
        promptOverrideConfiguration=prompt_override_config()
    )
    agent_id = resp["agent"]["agentId"]
    print(f"  Created agent: {agent_name} ({agent_id})")
    # Wait for agent to leave CREATING state
    _wait_for_agent(bedrock_agent_client, agent_id, "NOT_PREPARED")

    # Attach KB
    bedrock_agent_client.associate_agent_knowledge_base(
        agentId=agent_id,
        agentVersion="DRAFT",
        knowledgeBaseId=kb_id,
        description=f"Knowledge base for {agent_name}"
    )
    print(f"  Attached knowledge base {kb_id} to agent")

    _ensure_marker_action_group(bedrock_agent_client, agent_id)
    if geojson_lambda_arn:
        _ensure_lambda_action_group(bedrock_agent_client, agent_id, "live-data", geojson_lambda_arn, GEOJSON_FUNCTION_SCHEMA)
    else:
        print(f"  Skipping live-data action group (no Lambda ARN available)")
    if arcgis_lambda_arn:
        _ensure_lambda_action_group(bedrock_agent_client, agent_id, "geocode", arcgis_lambda_arn, GEOCODE_FUNCTION_SCHEMA)
    else:
        print(f"  Skipping geocode action group (no Lambda ARN available)")

    # Prepare agent (required before creating alias)
    bedrock_agent_client.prepare_agent(agentId=agent_id)
    print(f"  Preparing agent...")
    _wait_for_agent(bedrock_agent_client, agent_id, "PREPARED")

    return agent_id


def ensure_agent_alias(bedrock_agent_client, agent_id, agent_name):
    alias_name = "live"
    # Ensure agent is prepared before creating/updating alias
    status = bedrock_agent_client.get_agent(agentId=agent_id)["agent"]["agentStatus"]
    if status == "NOT_PREPARED":
        print(f"  Agent is NOT_PREPARED, preparing...")
        bedrock_agent_client.prepare_agent(agentId=agent_id)
        _wait_for_agent(bedrock_agent_client, agent_id, "PREPARED")
    aliases = bedrock_agent_client.list_agent_aliases(agentId=agent_id)["agentAliasSummaries"]
    existing_alias = next((a for a in aliases if a["agentAliasName"] == alias_name), None)

    if existing_alias:
        alias_id = existing_alias["agentAliasId"]
        old_version = existing_alias["routingConfiguration"][0]["agentVersion"] if existing_alias["routingConfiguration"] else None
        print(f"  Agent alias already exists: {alias_name} ({alias_id}), currently -> version {old_version}")
        # Deploy the latest DRAFT changes to production. Omitting routingConfiguration
        # makes Bedrock create a new immutable version from DRAFT and repoint the alias
        # to it -- without this, DRAFT changes (model, instructions, KBs, action groups)
        # never reach live traffic on subsequent runs of this script.
        bedrock_agent_client.update_agent_alias(
            agentId=agent_id,
            agentAliasId=alias_id,
            agentAliasName=alias_name
        )
        _wait_for_alias(bedrock_agent_client, agent_id, alias_id, "PREPARED")
        new_alias = bedrock_agent_client.get_agent_alias(agentId=agent_id, agentAliasId=alias_id)["agentAlias"]
        new_version = new_alias["routingConfiguration"][0]["agentVersion"]
        print(f"  Deployed latest DRAFT to production: alias {alias_name} now -> version {new_version}")
        return alias_id

    resp = bedrock_agent_client.create_agent_alias(
        agentId=agent_id,
        agentAliasName=alias_name
    )
    alias_id = resp["agentAlias"]["agentAliasId"]
    _wait_for_alias(bedrock_agent_client, agent_id, alias_id, "PREPARED")
    print(f"  Created agent alias: {alias_name} ({alias_id})")
    return alias_id


def _wait_for_agent(bedrock_agent_client, agent_id, target_status, timeout=120):
    for _ in range(timeout // 5):
        status = bedrock_agent_client.get_agent(agentId=agent_id)["agent"]["agentStatus"]
        if status == target_status:
            return
        if "FAILED" in status:
            raise RuntimeError(f"Agent entered failed state: {status}")
        time.sleep(5)
    raise TimeoutError(f"Agent did not reach {target_status} within {timeout}s")


def _wait_for_alias(bedrock_agent_client, agent_id, alias_id, target_status, timeout=120):
    for _ in range(timeout // 5):
        status = bedrock_agent_client.get_agent_alias(agentId=agent_id, agentAliasId=alias_id)["agentAlias"]["agentAliasStatus"]
        if status == target_status:
            return
        if "FAILED" in status:
            raise RuntimeError(f"Agent alias entered failed state: {status}")
        time.sleep(5)
    raise TimeoutError(f"Agent alias did not reach {target_status} within {timeout}s")


def write_ssm(ssm_client, ssm_prefix, kb_name, kb_id, agent_id, alias_id):
    base = f"{ssm_prefix}/bedrock/{kb_name}"
    params = {
        f"{base}/kb-id": kb_id,
        f"{base}/agent-id": agent_id,
        f"{base}/agent-alias-id": alias_id,
    }
    for name, value in params.items():
        ssm_client.put_parameter(Name=name, Value=value, Type="String", Overwrite=True)
        print(f"  SSM: {name} = {value}")


def main():
    parser = argparse.ArgumentParser(description="Setup Bedrock Agent with Knowledge Base")
    parser.add_argument("--environment", required=True, help="Environment name, e.g. Demo or Prod (stack: TAK-<env>-BaseInfra)")
    parser.add_argument("--kb-name", required=True, help="Knowledge base name / S3 subfolder (e.g. nema-cdem)")
    parser.add_argument("--agent-name", required=True, help="Bedrock Agent display name")
    parser.add_argument("--system-prompt", default=None, help="Agent instruction text")
    parser.add_argument("--system-prompt-file", default=None, help="Path to file containing agent instruction (e.g. nz_rag_responder.txt)")
    parser.add_argument("--ssm-prefix", default=None, help="SSM parameter prefix (default: /tak/<environment-lowercase>)")
    parser.add_argument("--profile", default=None, help="AWS profile name")
    parser.add_argument("--region", default=None, help="AWS region (default: profile region or ap-southeast-2)")
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    region = args.region or session.region_name or "ap-southeast-2"
    session = boto3.Session(profile_name=args.profile, region_name=region)
    cf = session.client("cloudformation")
    iam = session.client("iam")
    sts = session.client("sts")
    bedrock_agent = session.client("bedrock-agent")
    ssm = session.client("ssm")

    account_id = get_account_id(sts)
    stack_name = f"TAK-{args.environment}-BaseInfra"
    ssm_prefix = args.ssm_prefix or f"/tak/{args.environment.lower()}"
    model_id = default_model_id(region)
    print(f"Account: {account_id}, Region: {region}")

    tak_infra_stack_name = f"TAK-{args.environment}-TakInfra"

    print(f"\n[1/6] Resolving artifacts bucket from stack {stack_name}...")
    base_outputs = get_stack_outputs(cf, stack_name)
    bucket_name, kms_key_arn = get_artifacts_bucket(base_outputs)
    print(f"  Bucket: {bucket_name}")
    if kms_key_arn:
        print(f"  KMS key: {kms_key_arn}")

    geojson_lambda_arn = get_lambda_arn(cf, tak_infra_stack_name, "GeoJson")
    if geojson_lambda_arn:
        print(f"  GeoJSON Lambda ARN: {geojson_lambda_arn}")
    else:
        print(f"  GeoJSON Lambda not found in {tak_infra_stack_name} (will skip live-data action group)")

    arcgis_lambda_arn = get_lambda_arn(cf, tak_infra_stack_name, "ArcGis")
    if arcgis_lambda_arn:
        print(f"  ArcGIS Lambda ARN: {arcgis_lambda_arn}")
    else:
        print(f"  ArcGIS Lambda not found in {tak_infra_stack_name} (will skip geocode action group)")

    print(f"\n[2/6] Ensuring S3 prefix exists: bedrock-kb/{args.kb_name}/")
    s3 = session.client("s3")
    s3.put_object(Bucket=bucket_name, Key=f"bedrock-kb/{args.kb_name}/.keep", Body=b"")
    print(f"  Created s3://{bucket_name}/bedrock-kb/{args.kb_name}/")

    agent_role_name = f"BedrockAgentRole-{args.kb_name}"


    print(f"\n[3/6] Ensuring agent IAM role...")
    agent_role_arn = ensure_agent_iam_role(iam, agent_role_name, region, account_id)

    if args.system_prompt_file:
        with open(args.system_prompt_file, "r") as f:
            system_prompt = f.read().strip()
    elif args.system_prompt:
        system_prompt = args.system_prompt
    else:
        print("Error: provide --system-prompt or --system-prompt-file", file=sys.stderr)
        sys.exit(1)

    print(f"\n[4/6] Resolving knowledge base from stack {tak_infra_stack_name}...")
    kb_id, ds_id = get_knowledge_base_ids(cf, tak_infra_stack_name, args.kb_name)
    print(f"  Knowledge base: {kb_id}, data source: {ds_id}")
    ensure_knowledge_base_synced(bedrock_agent, kb_id, ds_id)
    print(f"\n[5/6] Ensuring Agent: {args.agent_name}...")
    agent_id = ensure_agent(bedrock_agent, args.agent_name, agent_role_arn, system_prompt, kb_id, region, model_id, geojson_lambda_arn, arcgis_lambda_arn)

    print(f"\n[5b] Ensuring Agent alias...")
    alias_id = ensure_agent_alias(bedrock_agent, agent_id, args.agent_name)

    print(f"\n[6/6] Writing to SSM Parameter Store...")
    write_ssm(ssm, ssm_prefix, args.kb_name, kb_id, agent_id, alias_id)

    print(f"""
Done! Add to your bot YAML config:
  modelType: bedrock
  agentId: {agent_id}
  agentAliasId: {alias_id}

Or read from SSM at runtime:
  {ssm_prefix}/bedrock/{args.kb_name}/agent-id
  {ssm_prefix}/bedrock/{args.kb_name}/agent-alias-id
""")


if __name__ == "__main__":
    main()
