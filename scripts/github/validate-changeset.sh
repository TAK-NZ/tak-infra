#!/bin/bash
# CloudFormation change set validation

STACK_NAME=${1}
CHANGE_SET_NAME="breaking-change-check-$(date +%s)"

echo "🔍 Creating CloudFormation change set for $STACK_NAME..."

# Check if stack exists
if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  echo "✅ Stack does not exist - skipping change set validation for initial deployment"
  exit 0
fi

# Generate CDK template with same context as deployment
npm run cdk synth -- --context envType=prod --context stackName=Demo > template.json

# Create change set
aws cloudformation create-change-set \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET_NAME" \
  --template-body file://template.json \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM

# Wait for change set creation
aws cloudformation wait change-set-create-complete \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET_NAME"

# Analyze change set for resource replacements
REPLACEMENTS=$(aws cloudformation describe-change-set \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET_NAME" \
  --query 'Changes[?ResourceChange.Replacement==`True`].ResourceChange.LogicalResourceId' \
  --output text)

# Clean up change set
aws cloudformation delete-change-set \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET_NAME"

if [ -n "$REPLACEMENTS" ]; then
  echo "❌ Resource replacements detected:"
  echo "$REPLACEMENTS"
  echo "💡 Use '[force-deploy]' in commit message to override"
  exit 1
else
  echo "✅ No resource replacements detected"
fi