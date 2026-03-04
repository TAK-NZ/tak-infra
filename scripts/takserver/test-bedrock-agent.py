#!/usr/bin/env python3
"""
Test Bedrock Agent invocation to verify agent configuration and response handling.
"""

import boto3
import argparse
import json
import sys

def test_bedrock_agent(region, agent_id, agent_alias_id, message):
    """Test Bedrock Agent invocation"""
    
    print(f"Testing Bedrock Agent in {region}")
    print(f"Agent ID: {agent_id}")
    print(f"Agent Alias ID: {agent_alias_id}")
    print(f"Message: {message}\n")
    
    try:
        client = boto3.client('bedrock-agent-runtime', region_name=region)
        
        session_id = f"test-session-{int(boto3.Session().get_credentials().access_key[-6:], 36)}"
        
        response = client.invoke_agent(
            agentId=agent_id,
            agentAliasId=agent_alias_id,
            sessionId=session_id,
            inputText=message
        )
        
        print("Response received:")
        print("-" * 80)
        
        # Process streaming response
        result_text = []
        for event in response['completion']:
            if 'chunk' in event:
                chunk = event['chunk']
                if 'bytes' in chunk:
                    text = chunk['bytes'].decode('utf-8')
                    result_text.append(text)
                    print(text, end='', flush=True)
        
        print("\n" + "-" * 80)
        print(f"\nFull response: {''.join(result_text)}")
        print("\n✅ Agent invocation successful!")
        return True
        
    except client.exceptions.ResourceNotFoundException as e:
        print(f"❌ Agent not found: {e}")
        return False
    except client.exceptions.AccessDeniedException as e:
        print(f"❌ Access denied: {e}")
        print("\nRequired IAM permissions:")
        print("  - bedrock:InvokeAgent")
        print(f"  - Resource: arn:aws:bedrock:{region}:ACCOUNT_ID:agent/{agent_id}")
        print(f"  - Resource: arn:aws:bedrock:{region}:ACCOUNT_ID:agent-alias/{agent_id}/{agent_alias_id}")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description='Test Bedrock Agent invocation')
    parser.add_argument('--region', default='ap-southeast-2', help='AWS region (default: ap-southeast-2)')
    parser.add_argument('--agent-id', required=True, help='Bedrock Agent ID')
    parser.add_argument('--agent-alias-id', default='TSTALIASID', help='Agent Alias ID (default: TSTALIASID)')
    parser.add_argument('--message', default='What is the weather like today?', help='Test message')
    
    args = parser.parse_args()
    
    success = test_bedrock_agent(args.region, args.agent_id, args.agent_alias_id, args.message)
    sys.exit(0 if success else 1)

if __name__ == '__main__':
    main()
