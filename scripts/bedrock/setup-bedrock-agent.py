#!/usr/bin/env python3
"""
Setup a Bedrock Agent with an attached Knowledge Base sourced from an S3 prefix.

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
import sys
import time
import boto3
from botocore.exceptions import ClientError
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials
import urllib.request


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


def ensure_kb_iam_role(iam_client, role_name, bucket_name, region, account_id, kms_key_arn=None):
    trust = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "bedrock.amazonaws.com"},
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {"aws:SourceAccount": account_id},
                "ArnLike": {"aws:SourceArn": f"arn:aws:bedrock:{region}:{account_id}:knowledge-base/*"}
            }
        }]
    }
    statements = [
        {
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:ListBucket"],
            "Resource": [f"arn:aws:s3:::{bucket_name}", f"arn:aws:s3:::{bucket_name}/*"]
        },
        {
            "Effect": "Allow",
            "Action": "bedrock:InvokeModel",
            "Resource": f"arn:aws:bedrock:{region}::foundation-model/amazon.titan-embed-text-v2:0"
        },
        {
            "Effect": "Allow",
            "Action": "aoss:APIAccessAll",
            "Resource": f"arn:aws:aoss:{region}:{account_id}:collection/*"
        }
    ]
    if kms_key_arn:
        statements.append({
            "Effect": "Allow",
            "Action": ["kms:Decrypt", "kms:GenerateDataKey"],
            "Resource": kms_key_arn
        })
    policy = {"Version": "2012-10-17", "Statement": statements}
    try:
        role = iam_client.get_role(RoleName=role_name)["Role"]
        print(f"  IAM role already exists: {role_name}")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
        role = iam_client.create_role(
            RoleName=role_name,
            AssumeRolePolicyDocument=json.dumps(trust),
            Description="Bedrock Knowledge Base S3 access role"
        )["Role"]
        print(f"  Created IAM role: {role_name}")
        time.sleep(10)  # IAM propagation
    iam_client.put_role_policy(
        RoleName=role_name,
        PolicyName="BedrockKBPolicy",
        PolicyDocument=json.dumps(policy)
    )
    return role["Arn"]


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
    model_id = "us.anthropic.claude-sonnet-4-6" if region.startswith("us-") else "au.anthropic.claude-sonnet-4-6"
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


def ensure_aoss_index(session, collection_endpoint, index_name):
    """Create the vector index in AOSS if it doesn't exist, using SigV4 signed requests."""
    import urllib.request, urllib.error, hashlib
    credentials = session.get_credentials().get_frozen_credentials()
    region = session.region_name
    url = f"{collection_endpoint}/{index_name}"

    def signed_request(method, url, body=None):
        from urllib.parse import urlparse
        host = urlparse(url).netloc
        body_hash = hashlib.sha256(body).hexdigest() if body else "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        req = AWSRequest(method=method, url=url, data=body,
                         headers={"Content-Type": "application/json", "host": host,
                                  "x-amz-content-sha256": body_hash})
        SigV4Auth(credentials, "aoss", region).add_auth(req)
        prepared = req.prepare()
        headers = dict(prepared.headers)
        headers["host"] = host
        headers["x-amz-content-sha256"] = body_hash
        http_req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(http_req) as resp:
                body_resp = resp.read()
                return resp.status, json.loads(body_resp) if body_resp else {}
        except urllib.error.HTTPError as e:
            body_resp = e.read()
            return e.code, json.loads(body_resp) if body_resp else {}

    status, body = signed_request("HEAD", url)
    if status == 200:
        print(f"  AOSS index already exists: {index_name}")
        return

    index_body = json.dumps({
        "settings": {"index": {"knn": True}},
        "mappings": {"properties": {
            "embedding": {"type": "knn_vector", "dimension": 1024,
                          "method": {"name": "hnsw", "engine": "faiss",
                                     "parameters": {"ef_construction": 512, "m": 16}}},
            "text": {"type": "text"},
            "metadata": {"type": "text"}
        }}
    }).encode()
    status, body = signed_request("PUT", url, index_body)
    if status not in (200, 201):
        raise RuntimeError(f"Failed to create AOSS index {index_name}: {status} {body}")
    print(f"  Created AOSS index: {index_name}")
    time.sleep(20)  # Wait for index to be visible to Bedrock


def ensure_aoss_collection(aoss_client, collection_name, kb_role_arn, account_id, caller_arn):
    # Encryption policy (required before collection creation)
    enc_policy_name = f"{collection_name}-enc"
    try:
        aoss_client.get_security_policy(name=enc_policy_name, type="encryption")
        print(f"  AOSS encryption policy already exists: {enc_policy_name}")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        aoss_client.create_security_policy(
            name=enc_policy_name,
            type="encryption",
            policy=json.dumps({"Rules": [{"ResourceType": "collection", "Resource": [f"collection/{collection_name}"]}], "AWSOwnedKey": True})
        )
        print(f"  Created AOSS encryption policy: {enc_policy_name}")

    # Network policy (public access for Bedrock to reach it)
    net_policy_name = f"{collection_name}-net"
    try:
        aoss_client.get_security_policy(name=net_policy_name, type="network")
        print(f"  AOSS network policy already exists: {net_policy_name}")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        aoss_client.create_security_policy(
            name=net_policy_name,
            type="network",
            policy=json.dumps([{"Rules": [{"ResourceType": "collection", "Resource": [f"collection/{collection_name}"]}, {"ResourceType": "dashboard", "Resource": [f"collection/{collection_name}"]}], "AllowFromPublic": True}])
        )
        print(f"  Created AOSS network policy: {net_policy_name}")

    # Collection
    existing = aoss_client.list_collections(collectionFilters={"name": collection_name})["collectionSummaries"]
    if existing:
        collection_id = existing[0]["id"]
        collection_arn = existing[0]["arn"]
        print(f"  AOSS collection already exists: {collection_name} ({collection_id})")
    else:
        resp = aoss_client.create_collection(name=collection_name, type="VECTORSEARCH")
        collection_id = resp["createCollectionDetail"]["id"]
        collection_arn = resp["createCollectionDetail"]["arn"]
        print(f"  Created AOSS collection: {collection_name} ({collection_id}), waiting for ACTIVE...")
        for _ in range(120):  # up to 10 minutes
            status = aoss_client.batch_get_collection(ids=[collection_id])["collectionDetails"][0]["status"]
            if status == "ACTIVE":
                break
            if status == "FAILED":
                raise RuntimeError(f"AOSS collection {collection_name} failed to create")
            time.sleep(5)
        else:
            raise TimeoutError(f"AOSS collection {collection_name} did not become ACTIVE")
        print(f"  AOSS collection is ACTIVE")

    # Data access policy — grants KB role index/document permissions
    access_policy_name = f"{collection_name}-access"
    access_policy_doc = json.dumps([{
        "Rules": [
            {"ResourceType": "index", "Resource": [f"index/{collection_name}/*"],
             "Permission": ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]},
            {"ResourceType": "collection", "Resource": [f"collection/{collection_name}"],
             "Permission": ["aoss:CreateCollectionItems", "aoss:DeleteCollectionItems", "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"]}
        ],
        "Principal": [kb_role_arn, caller_arn]
    }])
    try:
        existing_policy = aoss_client.get_access_policy(name=access_policy_name, type="data")["accessPolicyDetail"]
        try:
            aoss_client.update_access_policy(
                name=access_policy_name, type="data",
                policy=access_policy_doc,
                policyVersion=existing_policy["policyVersion"]
            )
            print(f"  Updated AOSS data access policy: {access_policy_name}")
            time.sleep(20)
        except ClientError as ue:
            if ue.response["Error"]["Code"] == "ValidationException" and "No changes" in str(ue):
                print(f"  AOSS data access policy unchanged: {access_policy_name}")
            else:
                raise
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        aoss_client.create_access_policy(name=access_policy_name, type="data", policy=access_policy_doc)
        print(f"  Created AOSS data access policy: {access_policy_name}")
        time.sleep(45)

    # Wait for ACTIVE and get endpoint (collection may still be CREATING)
    for _ in range(120):
        detail = aoss_client.batch_get_collection(ids=[collection_id])["collectionDetails"][0]
        if detail["status"] == "ACTIVE":
            break
        if detail["status"] == "FAILED":
            raise RuntimeError(f"AOSS collection {collection_name} is in FAILED state")
        print(f"  Waiting for collection to become ACTIVE (status: {detail['status']})...")
        time.sleep(5)
    else:
        raise TimeoutError(f"AOSS collection {collection_name} did not become ACTIVE")
    collection_endpoint = detail["collectionEndpoint"]
    return collection_arn, collection_endpoint


def ensure_knowledge_base(bedrock_agent_client, kb_name, role_arn, bucket_name, s3_prefix, region, collection_arn):
    # Check if KB already exists by name
    paginator = bedrock_agent_client.get_paginator("list_knowledge_bases")
    for page in paginator.paginate():
        for kb in page["knowledgeBaseSummaries"]:
            if kb["name"] == kb_name:
                print(f"  Knowledge base already exists: {kb_name} ({kb['knowledgeBaseId']})")
                return kb["knowledgeBaseId"]

    resp = bedrock_agent_client.create_knowledge_base(
        name=kb_name,
        roleArn=role_arn,
        knowledgeBaseConfiguration={
            "type": "VECTOR",
            "vectorKnowledgeBaseConfiguration": {
                "embeddingModelArn": f"arn:aws:bedrock:{region}::foundation-model/amazon.titan-embed-text-v2:0"
            }
        },
        storageConfiguration={
            "type": "OPENSEARCH_SERVERLESS",
            "opensearchServerlessConfiguration": {
                "collectionArn": collection_arn,
                "vectorIndexName": kb_name,
                "fieldMapping": {"vectorField": "embedding", "textField": "text", "metadataField": "metadata"}
            }
        }
    )
    kb_id = resp["knowledgeBase"]["knowledgeBaseId"]
    print(f"  Created knowledge base: {kb_name} ({kb_id})")

    # Add S3 data source
    bedrock_agent_client.create_data_source(
        knowledgeBaseId=kb_id,
        name=f"{kb_name}-s3",
        dataSourceConfiguration={
            "type": "S3",
            "s3Configuration": {
                "bucketArn": f"arn:aws:s3:::{bucket_name}",
                "inclusionPrefixes": [f"bedrock-kb/{s3_prefix}/"]
            }
        }
    )
    print(f"  Created data source: s3://{bucket_name}/bedrock-kb/{s3_prefix}/")

    # Trigger initial sync
    data_sources = bedrock_agent_client.list_data_sources(knowledgeBaseId=kb_id)["dataSourceSummaries"]
    ds_id = data_sources[0]["dataSourceId"]
    bedrock_agent_client.start_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id)
    print(f"  Started initial KB sync")

    return kb_id


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
                    idleSessionTTLInSeconds=1800
                )
                print(f"  Updated agent instruction")
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
        idleSessionTTLInSeconds=1800
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
    # Ensure agent is prepared before creating alias
    status = bedrock_agent_client.get_agent(agentId=agent_id)["agent"]["agentStatus"]
    if status == "NOT_PREPARED":
        print(f"  Agent is NOT_PREPARED, preparing...")
        bedrock_agent_client.prepare_agent(agentId=agent_id)
        _wait_for_agent(bedrock_agent_client, agent_id, "PREPARED")
    aliases = bedrock_agent_client.list_agent_aliases(agentId=agent_id)["agentAliasSummaries"]
    for alias in aliases:
        if alias["agentAliasName"] == alias_name:
            print(f"  Agent alias already exists: {alias_name} ({alias['agentAliasId']})")
            return alias["agentAliasId"]

    resp = bedrock_agent_client.create_agent_alias(
        agentId=agent_id,
        agentAliasName=alias_name
    )
    alias_id = resp["agentAlias"]["agentAliasId"]
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
    caller_arn = sts.get_caller_identity()["Arn"]
    # Normalize assumed-role session ARN to role ARN for AOSS data access policy
    if ":assumed-role/" in caller_arn:
        parts = caller_arn.split("/")
        caller_arn = f"arn:aws:iam::{account_id}:role/{parts[1]}"
    stack_name = f"TAK-{args.environment}-BaseInfra"
    ssm_prefix = args.ssm_prefix or f"/tak/{args.environment.lower()}"
    model_id = "us.anthropic.claude-sonnet-4-6" if region.startswith("us-") else "au.anthropic.claude-sonnet-4-6"
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

    kb_role_name = f"BedrockKBRole-{args.kb_name}"
    agent_role_name = f"BedrockAgentRole-{args.kb_name}"

    aoss = session.client("opensearchserverless")

    print(f"\n[3/6] Ensuring IAM roles...")
    kb_role_arn = ensure_kb_iam_role(iam, kb_role_name, bucket_name, region, account_id, kms_key_arn)
    agent_role_arn = ensure_agent_iam_role(iam, agent_role_name, region, account_id)

    if args.system_prompt_file:
        with open(args.system_prompt_file, "r") as f:
            system_prompt = f.read().strip()
    elif args.system_prompt:
        system_prompt = args.system_prompt
    else:
        print("Error: provide --system-prompt or --system-prompt-file", file=sys.stderr)
        sys.exit(1)

    print(f"\n[3b] Ensuring OpenSearch Serverless collection: {args.kb_name}...")
    collection_arn, collection_endpoint = ensure_aoss_collection(aoss, args.kb_name, kb_role_arn, account_id, caller_arn)

    print(f"  Ensuring AOSS vector index: {args.kb_name}...")
    ensure_aoss_index(session, collection_endpoint, args.kb_name)

    print(f"\n[4/6] Ensuring Knowledge Base: {args.kb_name}...")
    kb_id = ensure_knowledge_base(bedrock_agent, args.kb_name, kb_role_arn, bucket_name, args.kb_name, region, collection_arn)

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
