require('dotenv').config();
const { handler } = require('./index');

// Mock event for local testing
const mockEvent = {
  RequestType: 'Create',
  ResourceProperties: {
    ServiceToken: 'mock-service-token',
    timestamp: new Date().toISOString(),
  },
  ResponseURL: 'https://example.com/response',
  StackId: 'mock-stack-id',
  RequestId: 'mock-request-id',
  LogicalResourceId: 'mock-resource-id',
  ResourceType: 'Custom::WebTakOidcSetup',
};

// Mock context for local testing
const mockContext = {
  logStreamName: 'mock-log-stream',
  functionName: 'mock-function-name',
};

// Set environment variables for local testing
// For local testing, use AUTHENTIK_ADMIN_TOKEN directly instead of Secrets Manager
if (!process.env.AUTHENTIK_ADMIN_TOKEN) {
  console.error('Error: AUTHENTIK_ADMIN_TOKEN environment variable is required for local testing');
  console.error('Please set it in your .env file or environment');
  process.exit(1);
}

// Don't set AUTHENTIK_ADMIN_SECRET_ARN for local testing - this forces the function to use the token directly
process.env.PROVIDER_NAME = process.env.PROVIDER_NAME || 'TAK-WebTAK';
process.env.APPLICATION_NAME = process.env.APPLICATION_NAME || 'WebTAK';
process.env.APPLICATION_SLUG = process.env.APPLICATION_SLUG || 'tak-webtak';
process.env.REDIRECT_URIS = process.env.REDIRECT_URIS || JSON.stringify(['https://ops.tak.nz/login/redirect']);
process.env.LAUNCH_URL = process.env.LAUNCH_URL || 'https://ops.tak.nz';
process.env.OPEN_IN_NEW_TAB = process.env.OPEN_IN_NEW_TAB || 'true';
process.env.APPLICATION_DESCRIPTION = process.env.APPLICATION_DESCRIPTION || 'Web-based geospatial collaboration platform (Legacy system).';
process.env.AUTHENTICATION_FLOW_NAME = process.env.AUTHENTICATION_FLOW_NAME || '';
process.env.AUTHORIZATION_FLOW_NAME = process.env.AUTHORIZATION_FLOW_NAME || 'default-provider-authorization-implicit-consent';
process.env.INVALIDATION_FLOW_NAME = process.env.INVALIDATION_FLOW_NAME || 'default-provider-invalidation-flow';
process.env.GROUP_NAME = process.env.GROUP_NAME || 'Team Awareness Kit';
process.env.LDAP_GROUP_PREFIX = process.env.LDAP_GROUP_PREFIX || 'tak_';

// Run the handler
async function runTest() {
  try {
    console.log('Running WebTAK OIDC setup test with event:', JSON.stringify(mockEvent, null, 2));
    const result = await handler(mockEvent, mockContext);
    console.log('Result:', JSON.stringify(result, null, 2));
    
    // Display OIDC endpoints for validation
    if (result.Data) {
      console.log('\n=== WebTAK OIDC Configuration ===');
      console.log(`Issuer: ${result.Data.issuer}`);
      console.log(`Authorize URL: ${result.Data.authorizeUrl}`);
      console.log(`Token URL: ${result.Data.tokenUrl}`);
      console.log(`UserInfo URL: ${result.Data.userInfoUrl}`);
      console.log(`JWKS URI: ${result.Data.jwksUri}`);
      console.log(`Client ID: ${result.Data.clientId}`);
      console.log(`Client Secret: ${result.Data.clientSecret ? '***' : 'Not available'}`);
      console.log('================================\n');
    }
  } catch (error) {
    console.error('Error:', error);
  }
}

runTest();