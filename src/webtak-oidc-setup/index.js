const { SecretsManagerClient, ListSecretsCommand, GetSecretValueCommand, PutSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const axios = require('axios');
const fs = require('fs');
const path = require('path');
const FormData = require('form-data');

// Main handler function for the Lambda
exports.handler = async (event, context) => {
  console.log('Event:', JSON.stringify(event, null, 2));
  console.log('Environment variables:', {
    AUTHENTIK_URL: process.env.AUTHENTIK_URL,
    AUTHENTIK_ADMIN_SECRET_ARN: process.env.AUTHENTIK_ADMIN_SECRET_ARN ? '***' : undefined,
    PROVIDER_NAME: process.env.PROVIDER_NAME,
    APPLICATION_NAME: process.env.APPLICATION_NAME,
    APPLICATION_SLUG: process.env.APPLICATION_SLUG,
    REDIRECT_URIS: process.env.REDIRECT_URIS,
    LAUNCH_URL: process.env.LAUNCH_URL,
  });
  
  try {
    // For local testing, use the token from environment variable if available
    let adminToken = process.env.AUTHENTIK_ADMIN_TOKEN;
    
    // In Lambda environment, get token from Secrets Manager
    if (!adminToken) {
      try {
        console.log('Getting admin token from Secrets Manager');
        const secretsManager = new SecretsManagerClient();
        let secretName = process.env.AUTHENTIK_ADMIN_SECRET_ARN;
      
      console.log(`Secret ARN: ${secretName}`);
      
      if (!secretName) {
        console.log('No secret ARN provided, attempting to find by name');
        const listCommand = new ListSecretsCommand({
          Filters: [{ Key: 'name', Values: ['AuthentikAdminToken'] }]
        });
        const listResponse = await secretsManager.send(listCommand);
        secretName = listResponse.SecretList[0].ARN;
        console.log(`Found secret ARN: ${secretName}`);
      }
      
      console.log('Retrieving secret value...');
      const getCommand = new GetSecretValueCommand({ SecretId: secretName });
      const secretData = await secretsManager.send(getCommand);
      console.log('Secret retrieved successfully');
      
      try {
        const secret = JSON.parse(secretData.SecretString);
        adminToken = secret.token;
        
        if (!adminToken) {
          throw new Error('Admin token not found in secret. Secret should contain a "token" field.');
        }
        } catch (parseError) {
          console.log('Failed to parse secret as JSON, using raw string as token');
          adminToken = secretData.SecretString;
        }
      } catch (error) {
        console.error('Error retrieving secret:', error);
        if (error.name === 'AccessDeniedException' && error.message.includes('KMS')) {
          console.error('KMS access denied. Make sure the Lambda has permission to use the KMS key that encrypts the secret.');
        }
        throw error;
      }
    }
    
    // Configure axios for Authentik API
    const authentikUrl = process.env.AUTHENTIK_URL;
    const api = axios.create({
      baseURL: authentikUrl,
      headers: {
        'Authorization': `Bearer ${adminToken}`,
        'Content-Type': 'application/json',
      },
    });
    
    // Handle CloudFormation custom resource events
    if (event.RequestType === 'Delete') {
      console.log('Handling DELETE request - no cleanup needed, preserving Authentik resources');
      return {
        PhysicalResourceId: event.PhysicalResourceId || 'webtak-oidc-setup',
        Status: 'SUCCESS',
      };
    }
    
    // Get or create authentication flow
    const authenticationFlowName = process.env.AUTHENTICATION_FLOW_NAME || '';
    let authenticationFlow = authenticationFlowName ? 
      await getFlowByName(api, authenticationFlowName) : null;
    
    // Get or create authorization flow
    const authorizationFlowName = process.env.AUTHORIZATION_FLOW_NAME || 'default-provider-authorization-implicit-consent';
    let authorizationFlow = await getFlowByName(api, authorizationFlowName);
    
    // Get or create invalidation flow
    const invalidationFlowName = process.env.INVALIDATION_FLOW_NAME || 'default-provider-invalidation-flow';
    let invalidationFlow = await getFlowByName(api, invalidationFlowName);
    
    // Create or update OAuth2 provider
    const providerName = process.env.PROVIDER_NAME;
    const redirectUris = JSON.parse(process.env.REDIRECT_URIS).map(uri => ({
      url: uri,
      matching_mode: 'strict'
    }));
    
    // Get or create required scope mappings
    console.log('Setting up required scope mappings');
    const ldapGroupPrefix = process.env.LDAP_GROUP_PREFIX;
    let requiredScopes = ['email', 'openid', 'profile'];
    const scopeMappings = [];
    
    // Create custom profile scope mapping if ldapGroupPrefix is provided
    if (ldapGroupPrefix) {
      console.log(`Creating custom profile scope mapping with LDAP group prefix: ${ldapGroupPrefix}`);
      const customProfileMapping = await createCustomProfileScopeMapping(api, ldapGroupPrefix);
      scopeMappings.push(customProfileMapping.pk);
      // Replace 'profile' with custom scope
      requiredScopes = ['email', 'openid', 'profile-WebTak'];
    }
    
    for (const scope of requiredScopes) {
      if (scope === 'profile-WebTak' && ldapGroupPrefix) {
        // Already added above
        continue;
      }
      const mapping = await getOrCreateScopeMapping(api, scope);
      scopeMappings.push(mapping.pk);
    }
    
    // Get signing key if specified
    const signingKeyName = process.env.SIGNING_KEY_NAME;
    let signingKey = null;
    if (signingKeyName) {
      signingKey = await getSigningKeyByName(api, signingKeyName);
    }
    
    const provider = await createOrUpdateProvider(api, {
      name: providerName,
      authorization_flow: authorizationFlow.pk,
      invalidation_flow: invalidationFlow.pk,
      ...(authenticationFlow ? { authentication_flow: authenticationFlow.pk } : {}),
      redirect_uris: redirectUris,
      client_type: 'confidential',
      include_claims_in_id_token: true,
      access_code_validity: 'minutes=1',
      access_token_validity: 'minutes=5',
      refresh_token_validity: 'days=30',
      signing_key: signingKey,
      property_mappings: scopeMappings,
    });
    
    // Create or update application
    const applicationName = process.env.APPLICATION_NAME;
    const applicationSlug = process.env.APPLICATION_SLUG;
    const launchUrl = process.env.LAUNCH_URL;
    const openInNewTab = process.env.OPEN_IN_NEW_TAB === 'true';
    const description = process.env.APPLICATION_DESCRIPTION;
    const groupName = process.env.GROUP_NAME;
    
    const application = await createOrUpdateApplication(api, {
      name: applicationName,
      slug: applicationSlug,
      provider: provider.pk,
      meta_launch_url: launchUrl,
      open_in_new_tab: openInNewTab,
      ...(description ? { meta_description: description } : {}),
    });
    
    // Set application icon
    await uploadApplicationIcon(api, application.slug);
    
    // Assign group to application if specified
    if (groupName) {
      console.log(`Assigning group '${groupName}' to application`);
      await assignGroupToApplication(api, application.slug, groupName);
    }
    
    // Store client secret in Secrets Manager if provided
    const webTakOidcClientSecretArn = process.env.WEBTAK_OIDC_CLIENT_SECRET_ARN;
    if (webTakOidcClientSecretArn && provider.client_secret) {
      console.log('Storing WebTAK OIDC client secret in Secrets Manager');
      try {
        const secretsManager = new SecretsManagerClient();
        await secretsManager.send(new PutSecretValueCommand({
          SecretId: webTakOidcClientSecretArn,
          SecretString: provider.client_secret
        }));
        console.log('WebTAK OIDC client secret stored successfully');
      } catch (error) {
        console.error('Error storing WebTAK OIDC client secret:', error);
        // Don't fail the entire operation if secret storage fails
      }
    }
    
    // Get OIDC configuration endpoints
    console.log('Retrieving OIDC configuration endpoints');
    const oidcConfig = await getOidcConfiguration(authentikUrl, applicationSlug);
    console.log('OIDC configuration retrieved:', JSON.stringify(oidcConfig, null, 2));
    
    // Ensure client_id and client_secret are available
    if (!provider.client_id) {
      throw new Error('Provider client_id is missing in the response from Authentik');
    }
    
    if (!oidcConfig.issuer) {
      throw new Error('OIDC issuer is missing in the configuration');
    }
    
    // Return the client ID, secret, and OIDC endpoints
    const response = {
      PhysicalResourceId: application.pk.toString(),
      clientId: provider.client_id,
      clientSecret: provider.client_secret,
      issuer: oidcConfig.issuer,
      authorizeUrl: oidcConfig.authorizeUrl,
      tokenUrl: oidcConfig.tokenUrl,
      userInfoUrl: oidcConfig.userInfoUrl,
      jwksUri: oidcConfig.jwksUri,
      Data: {
        clientId: provider.client_id,
        clientSecret: provider.client_secret,
        providerName: providerName,
        issuer: oidcConfig.issuer,
        authorizeUrl: oidcConfig.authorizeUrl,
        tokenUrl: oidcConfig.tokenUrl,
        userInfoUrl: oidcConfig.userInfoUrl,
        jwksUri: oidcConfig.jwksUri,
      },
    };
    
    // For CloudFormation custom resources
    if (event.RequestType) {
      const cfnResponse = {
        Status: 'SUCCESS',
        PhysicalResourceId: response.PhysicalResourceId,
        StackId: event.StackId,
        RequestId: event.RequestId,
        LogicalResourceId: event.LogicalResourceId,
        Data: {
          ...response.Data,
          clientId: provider.client_id,
          clientSecret: provider.client_secret,
          issuer: response.Data.issuer,
          jwksUri: response.Data.jwksUri
        },
        clientId: provider.client_id,
        clientSecret: provider.client_secret,
        issuer: response.Data.issuer,
        jwksUri: response.Data.jwksUri
      };
      
      console.log('Returning CloudFormation response');
      return cfnResponse;
    }
    
    console.log('Returning successful response');
    return response;
  } catch (error) {
    console.error('Error:', error);
    
    if (event.RequestType) {
      let errorDetails = error.message;
      if (error.response && error.response.data) {
        errorDetails += ` - API Response: ${JSON.stringify(error.response.data)}`;
      }
      
      const errorResponse = {
        Status: 'FAILED',
        Reason: `Error: ${errorDetails}`,
        PhysicalResourceId: event.PhysicalResourceId || 'webtak-oidc-setup-failed',
        StackId: event.StackId,
        RequestId: event.RequestId,
        LogicalResourceId: event.LogicalResourceId,
        Data: {}
      };
      
      console.log('Returning error response:', JSON.stringify(errorResponse));
      return errorResponse;
    }
    
    throw error;
  }
};

// Helper function to get a flow by name
async function getFlowByName(api, name) {
  try {
    console.log(`Looking for flow: ${name}`);
    const response = await api.get('/api/v3/flows/instances/', {
      params: { name: name }
    });
    
    if (response.data.results && response.data.results.length > 0) {
      console.log(`Found flow with name: ${name}, pk: ${response.data.results[0].pk}`);
      return response.data.results[0];
    }
    
    const allFlows = await api.get('/api/v3/flows/instances/');
    
    const exactFlow = allFlows.data.results.find(flow => flow.slug === name);
    if (exactFlow) {
      console.log(`Found flow by slug: ${name}, pk: ${exactFlow.pk}`);
      return exactFlow;
    }
    
    if (name === 'default-provider-authorization-implicit-consent') {
      const implicitFlow = allFlows.data.results.find(flow => 
        flow.slug === 'default-provider-authorization-implicit-consent'
      );
      if (implicitFlow) {
        console.log(`Found implicit consent flow, pk: ${implicitFlow.pk}`);
        return implicitFlow;
      }
    }
    
    const fallbackFlow = allFlows.data.results.find(flow => 
      flow.slug === 'default-provider-authorization-implicit-consent' || 
      flow.slug === 'default-provider-authorization-explicit-consent'
    );
    
    if (fallbackFlow) {
      console.log(`Using fallback flow: ${fallbackFlow.slug}, pk: ${fallbackFlow.pk}`);
      return fallbackFlow;
    }
    
    throw new Error(`Flow not found: ${name}`);
  } catch (error) {
    console.error('Error getting flow:', error);
    throw error;
  }
}

// Helper function to create or update OAuth2 provider
async function createOrUpdateProvider(api, providerData) {
  try {
    const existingProviders = await api.get('/api/v3/providers/oauth2/', {
      params: { name: providerData.name }
    });
    
    let provider;
    
    if (existingProviders.data.results && existingProviders.data.results.length > 0) {
      const existingProvider = existingProviders.data.results[0];
      console.log(`Updating existing provider with ID ${existingProvider.pk}`);
      const response = await api.patch(`/api/v3/providers/oauth2/${existingProvider.pk}/`, providerData);
      provider = response.data;
    } else {
      console.log('Creating new OAuth2 provider');
      const response = await api.post('/api/v3/providers/oauth2/', providerData);
      provider = response.data;
    }
    
    if (!provider.client_id || !provider.client_secret) {
      console.log(`Provider created/updated, but client_id or client_secret is missing. Fetching provider details...`);
      const detailsResponse = await api.get(`/api/v3/providers/oauth2/${provider.pk}/`);
      provider = detailsResponse.data;
      
      console.log(`Provider details fetched. Has client_id: ${!!provider.client_id}, Has client_secret: ${!!provider.client_secret}`);
    }
    
    return provider;
  } catch (error) {
    console.error('Error creating/updating provider:', error.message);
    if (error.response) {
      console.error(`Status: ${error.response.status}`);
      if (error.response.data) {
        console.error('Error details:', JSON.stringify(error.response.data, null, 2));
      }
    }
    throw error;
  }
}

// Helper function to create or update application
async function createOrUpdateApplication(api, applicationData) {
  try {
    // Check if application exists using direct slug endpoint
    const response = await api.get(`/api/v3/core/applications/${applicationData.slug}/`);
    
    // Application exists, update it
    console.log(`Found existing application: ${response.data.name} (${response.data.slug})`);
    const updateResponse = await api.patch(`/api/v3/core/applications/${applicationData.slug}/`, applicationData);
    return updateResponse.data;
  } catch (error) {
    if (error.response && error.response.status === 404) {
      // Application doesn't exist, create it
      console.log('Application not found, creating new one');
      const response = await api.post('/api/v3/core/applications/', applicationData);
      return response.data;
    }
    console.error('Error creating/updating application:', error);
    if (error.response && error.response.data) {
      console.error('Error details:', JSON.stringify(error.response.data, null, 2));
    }
    throw error;
  }
}

// Helper function to create custom profile scope mapping for WebTAK
async function createCustomProfileScopeMapping(api, ldapGroupPrefix) {
  try {
    const scopeName = 'profile';
    const mappingName = 'profile-WebTak';
    
    // Check if custom scope mapping already exists
    const existingMappings = await api.get('/api/v3/propertymappings/provider/scope/', {
      params: { name: mappingName }
    });
    
    if (existingMappings.data.results && existingMappings.data.results.length > 0) {
      console.log(`Found existing custom profile scope mapping: ${mappingName}`);
      return existingMappings.data.results[0];
    }
    
    // Create custom profile scope mapping with LDAP group filtering
    const expression = `# Extract all groups the user is a member of
groups_temp = [group.name for group in user.ak_groups.filter(name__startswith='${ldapGroupPrefix}')]
groups = []

for group in groups_temp:
  group = regex_replace(group, '${ldapGroupPrefix}', '')
  groups.append(group)

return {
    "name": user.name,
    "preferred_username": user.username,
    "groups": groups,
}`;
    
    console.log(`Creating custom profile scope mapping: ${mappingName}`);
    const response = await api.post('/api/v3/propertymappings/provider/scope/', {
      name: mappingName,
      scope_name: scopeName,
      expression: expression,
      description: 'Custom profile scope for WebTAK with LDAP group filtering'
    });
    
    console.log(`Created custom profile scope mapping: ${mappingName}`);
    return response.data;
  } catch (error) {
    console.error(`Error creating custom profile scope mapping:`, error.message);
    if (error.response && error.response.data) {
      console.error('Error details:', JSON.stringify(error.response.data, null, 2));
    }
    throw error;
  }
}

// Helper function to get or create scope mapping
async function getOrCreateScopeMapping(api, scopeName) {
  try {
    const existingMappings = await api.get('/api/v3/propertymappings/provider/scope/', {
      params: { scope_name: scopeName }
    });
    
    if (existingMappings.data.results && existingMappings.data.results.length > 0) {
      console.log(`Found existing scope mapping for ${scopeName}`);
      return existingMappings.data.results[0];
    }
    
    console.log(`Creating new scope mapping for ${scopeName}`);
    const response = await api.post('/api/v3/propertymappings/provider/scope/', {
      name: `authentik default OAuth Mapping: OpenID '${scopeName}'`,
      scope_name: scopeName,
      expression: 'return {}',
      description: `Standard OpenID Connect scope: ${scopeName}`
    });
    
    return response.data;
  } catch (error) {
    console.error(`Error getting/creating scope mapping for ${scopeName}:`, error.message);
    if (error.response && error.response.data) {
      console.error('Error details:', JSON.stringify(error.response.data, null, 2));
    }
    throw error;
  }
}

// Helper function to get signing key by name
async function getSigningKeyByName(api, keyName) {
  try {
    console.log(`Looking for signing key: ${keyName}`);
    const response = await api.get('/api/v3/crypto/certificatekeypairs/', {
      params: { name: keyName }
    });
    
    if (response.data.results && response.data.results.length > 0) {
      const key = response.data.results[0];
      console.log(`Found signing key: ${keyName}, pk: ${key.pk}`);
      return key.pk;
    }
    
    console.warn(`Signing key '${keyName}' not found, using default`);
    return null;
  } catch (error) {
    console.error(`Error getting signing key '${keyName}':`, error.message);
    return null;
  }
}

// Helper function to get OIDC configuration endpoints
async function getOidcConfiguration(authentikUrl, applicationSlug) {
  try {
    console.log('Getting OIDC configuration');
    
    try {
      const appConfigUrl = `${authentikUrl}/application/o/${applicationSlug}/.well-known/openid-configuration`;
      console.log(`Trying application-specific configuration at: ${appConfigUrl}`);
      const appResponse = await axios.get(appConfigUrl);
      console.log('Retrieved application-specific OIDC configuration');
      
      return {
        issuer: appResponse.data.issuer,
        authorizeUrl: appResponse.data.authorization_endpoint,
        tokenUrl: appResponse.data.token_endpoint,
        userInfoUrl: appResponse.data.userinfo_endpoint,
        jwksUri: appResponse.data.jwks_uri
      };
    } catch (appError) {
      console.warn('Application-specific configuration not available:', appError.message);
      
      try {
        const wellKnownResponse = await axios.get(`${authentikUrl}/.well-known/openid-configuration`);
        console.log('Retrieved generic OIDC configuration from well-known endpoint');
        
        return {
          issuer: `${authentikUrl}/application/o/${applicationSlug}/`,
          authorizeUrl: wellKnownResponse.data.authorization_endpoint,
          tokenUrl: wellKnownResponse.data.token_endpoint,
          userInfoUrl: wellKnownResponse.data.userinfo_endpoint,
          jwksUri: wellKnownResponse.data.jwks_uri
        };
      } catch (wellKnownError) {
        console.warn('Could not retrieve OIDC configuration from well-known endpoint:', wellKnownError.message);
        
        const baseUrl = authentikUrl;
        return {
          issuer: `${baseUrl}/application/o/${applicationSlug}/`,
          authorizeUrl: `${baseUrl}/application/o/authorize/`,
          tokenUrl: `${baseUrl}/application/o/token/`,
          userInfoUrl: `${baseUrl}/application/o/userinfo/`,
          jwksUri: `${baseUrl}/application/o/jwks/`
        };
      }
    }
  } catch (error) {
    console.error('Error getting OIDC configuration:', error.message);
    if (error.response && error.response.data) {
      console.error('Error details:', JSON.stringify(error.response.data, null, 2));
    }
    
    return {
      issuer: `${authentikUrl}/application/o/${applicationSlug}/`,
      authorizeUrl: `${authentikUrl}/application/o/authorize/`,
      tokenUrl: `${authentikUrl}/application/o/token/`,
      userInfoUrl: `${authentikUrl}/application/o/userinfo/`,
      jwksUri: `${authentikUrl}/application/o/jwks/`
    };
  }
}

// Helper function to assign a group to an application
async function assignGroupToApplication(api, appSlug, groupName) {
  try {
    if (!groupName) {
      console.log('No group name provided, skipping group assignment');
      return null;
    }
    
    console.log(`Assigning group '${groupName}' to application '${appSlug}'`);
    
    // Update the application with the group name
    const response = await api.patch(`/api/v3/core/applications/${appSlug}/`, {
      group: groupName
    });
    
    console.log('Group assigned successfully');
    return response.data;
  } catch (error) {
    console.error('Error assigning group to application:', error.message);
    if (error.response && error.response.data) {
      console.error('Error details:', JSON.stringify(error.response.data, null, 2));
    }
    // Don't throw error for group assignment failures
    return null;
  }
}

// Helper function to upload application icon
async function uploadApplicationIcon(api, appSlug) {
  try {
    // Check if application already has an icon
    const appResponse = await api.get(`/api/v3/core/applications/${appSlug}/`);
    if (appResponse.data.meta_icon) {
      console.log(`Application ${appSlug} already has an icon, skipping upload`);
      return null;
    }
    
    // Use file upload instead of URL
    const iconPath = path.join(__dirname, 'tak-logo.png');
    console.log(`Uploading icon from: ${iconPath}`);
    
    if (!fs.existsSync(iconPath)) {
      console.warn(`Icon file not found at ${iconPath}`);
      return null;
    }
    
    const form = new FormData();
    form.append('file', fs.createReadStream(iconPath));
    
    const response = await api.post(`/api/v3/core/applications/${appSlug}/set_icon/`, form, {
      headers: {
        ...form.getHeaders(),
        'Content-Type': 'multipart/form-data',
      },
    });
    
    console.log('Icon uploaded successfully');
    return response.data;
  } catch (error) {
    console.error('Error uploading application icon:', error.message);
    if (error.response && error.response.data) {
      console.error('Error details:', JSON.stringify(error.response.data, null, 2));
    }
    // Don't throw error for icon upload failures
    return null;
  }
}

// Helper function to handle DELETE requests
async function handleDelete(api, resourceProperties, physicalResourceId) {
  try {
    const providerName = process.env.PROVIDER_NAME || resourceProperties.PROVIDER_NAME;
    const applicationName = process.env.APPLICATION_NAME || resourceProperties.APPLICATION_NAME;
    const applicationSlug = process.env.APPLICATION_SLUG || 
                           resourceProperties.APPLICATION_SLUG || 
                           applicationName?.toLowerCase().replace(/[^a-z0-9]/g, '-');
    
    console.log(`Cleaning up provider: ${providerName}, application: ${applicationSlug}`);
    
    // Delete application first
    if (applicationSlug) {
      try {
        console.log(`Deleting application: ${applicationSlug}`);
        await api.delete(`/api/v3/core/applications/${applicationSlug}/`);
        console.log(`Successfully deleted application: ${applicationSlug}`);
      } catch (error) {
        if (error.response?.status === 404) {
          console.log(`Application ${applicationSlug} not found, already deleted`);
        } else {
          console.warn(`Failed to delete application ${applicationSlug}:`, error.message);
        }
      }
    }
    
    // Delete OAuth2 provider
    if (providerName) {
      try {
        const providersResponse = await api.get('/api/v3/providers/oauth2/', {
          params: { name: providerName }
        });
        
        if (providersResponse.data.results && providersResponse.data.results.length > 0) {
          const provider = providersResponse.data.results[0];
          console.log(`Deleting provider: ${providerName} (ID: ${provider.pk})`);
          await api.delete(`/api/v3/providers/oauth2/${provider.pk}/`);
          console.log(`Successfully deleted provider: ${providerName}`);
        } else {
          console.log(`Provider ${providerName} not found, already deleted`);
        }
      } catch (error) {
        if (error.response?.status === 404) {
          console.log(`Provider ${providerName} not found, already deleted`);
        } else {
          console.warn(`Failed to delete provider ${providerName}:`, error.message);
        }
      }
    }
    
    console.log('Cleanup completed successfully');
  } catch (error) {
    console.error('Error during cleanup:', error.message);
  }
}