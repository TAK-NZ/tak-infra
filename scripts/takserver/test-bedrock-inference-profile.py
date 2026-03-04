#!/usr/bin/env python3
"""
Test script to verify AWS Bedrock inference profile support
Mimics the BedrockChatManager.java implementation
"""
import boto3
import json
import sys

def test_bedrock_model(model_id, region="us-west-2"):
    """Test a Bedrock model or inference profile"""
    print(f"Testing model: {model_id}")
    print(f"Region: {region}")
    print("-" * 60)
    
    # Create Bedrock Runtime client (same as Java SDK)
    client = boto3.client('bedrock-runtime', region_name=region)
    
    # Prepare request body (matches BedrockChatManager.java format)
    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 100,
        "messages": [
            {
                "role": "user",
                "content": "How can you help me?"
            }
        ]
    }
    
    try:
        # Invoke model (same API call as Java SDK)
        response = client.invoke_model(
            modelId=model_id,
            body=json.dumps(request_body)
        )
        
        # Parse response
        response_body = json.loads(response['body'].read())
        
        print("✓ SUCCESS!")
        print(f"Response: {response_body['content'][0]['text']}")
        print("-" * 60)
        return True
        
    except Exception as e:
        print(f"✗ FAILED!")
        print(f"Error: {str(e)}")
        print("-" * 60)
        return False

if __name__ == "__main__":
    print("AWS Bedrock Inference Profile Test")
    print("=" * 60)
    print()
    
    # Test inference profile
    print("Test 1: Claude Sonnet 4 via inference profile")
    success1 = test_bedrock_model("us.anthropic.claude-sonnet-4-6")
    print()
    
    # Test direct model (for comparison)
    print("Test 2: Claude 3.5 Haiku via direct model ID")
    success2 = test_bedrock_model("anthropic.claude-3-5-haiku-20241022-v1:0")
    print()
    
    # Summary
    print("=" * 60)
    print("SUMMARY:")
    print(f"  Inference profile (Claude Sonnet 4): {'✓ WORKS' if success1 else '✗ FAILED'}")
    print(f"  Direct model (Claude 3.5 Haiku):     {'✓ WORKS' if success2 else '✗ FAILED'}")
    print("=" * 60)
    
    sys.exit(0 if success1 else 1)
