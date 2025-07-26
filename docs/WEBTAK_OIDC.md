# WebTAK OIDC Integration Guide

This document explains the WebTAK OIDC (OpenID Connect) integration with Authentik, enabling secure single sign-on authentication for the TAK Server web interface.

## Overview

The WebTAK OIDC integration provides:
- **Automated Authentik Configuration**: Lambda function automatically sets up OIDC provider and application
- **Secure Authentication**: OAuth 2.0/OIDC flow with JWT tokens
- **Group-Based Access Control**: LDAP group integration for authorization
- **Flexible Configuration**: Environment-specific settings via `cdk.json`

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   User Browser  │    │    Authentik    │    │   TAK Server    │
│                 │    │  (Auth Server)  │    │   (WebTAK)      │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         │ 1. Access WebTAK      │                       │
         │──────────────────────────────────────────────▶│
         │                       │                       │
         │ 2. Redirect to Auth   │                       │
         │◀──────────────────────────────────────────────│
         │                       │                       │
         │ 3. Login Request      │                       │
         │──────────────────────▶│                       │
         │                       │                       │
         │ 4. Auth Code          │                       │
         │◀──────────────────────│                       │
         │                       │                       │
         │ 5. Auth Code + State  │                       │
         │──────────────────────────────────────────────▶│
         │                       │                       │
         │                       │ 6. Token Exchange     │
         │                       │◀──────────────────────│
         │                       │                       │
         │                       │ 7. Access Token       │
         │                       │──────────────────────▶│
         │                       │                       │
         │ 8. WebTAK Access      │                       │
         │◀──────────────────────────────────────────────│
```

## Configuration

### Enable OIDC Integration

Set `enableOidc: true` in the `webtak` section of `cdk.json`:

```json
{
  "context": {
    "dev-test": {
      "webtak": {
        "enableOidc": true,
        "providerName": "TAK-WebTAK",
        "applicationName": "WebTAK",
        "applicationSlug": "tak-webtak",
        "useTakServerLoginPage": false,
        "openInNewTab": true,
        "authenticationFlowName": "",
        "authorizationFlowName": "default-provider-authorization-implicit-consent",
        "invalidationFlowName": "default-provider-invalidation-flow",
        "groupName": "Team Awareness Kit",
        "description": "Web-based geospatial collaboration platform (Legacy system).",
        "iconPath": "src/webtak-oidc-setup/tak-logo.png",
        "signingKeyName": "authentik Self-signed Certificate"
      }
    }
  }
}
```

### Configuration Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `enableOidc` | Enable OIDC integration | `false` | Yes |
| `providerName` | OIDC provider name in Authentik | `TAK-WebTAK` | No |
| `applicationName` | Application display name | `WebTAK` | No |
| `applicationSlug` | URL slug for application | `tak-webtak` | No |
| `useTakServerLoginPage` | Use TAK Server's login page | `false` | No |
| `openInNewTab` | Open application in new browser tab | `true` | No |
| `authenticationFlowName` | Custom authentication flow | `""` (default) | No |
| `authorizationFlowName` | Authorization flow for consent | `default-provider-authorization-implicit-consent` | No |
| `invalidationFlowName` | Session invalidation flow | `default-provider-invalidation-flow` | No |
| `groupName` | LDAP group for access control | `Team Awareness Kit` | No |
| `description` | Application description | Auto-generated | No |
| `iconPath` | Path to application icon | `src/webtak-oidc-setup/tak-logo.png` | No |
| `signingKeyName` | Authentik signing key | `authentik Self-signed Certificate` | No |

## Authentication Flow

### 1. User Access
User navigates to WebTAK URL (e.g., `https://ops.tak.nz/webtak/`)

### 2. OAuth Redirect
TAK Server redirects to Authentik authorization endpoint:
```
https://account.tak.nz/application/o/authorize/?
  client_id=<client_id>&
  response_type=code&
  scope=openid+profile&
  redirect_uri=https://ops.tak.nz/login/redirect&
  state=<random_state>
```

### 3. User Authentication
User authenticates with Authentik (LDAP credentials)

### 4. Authorization Grant
Authentik redirects back with authorization code:
```
https://ops.tak.nz/login/redirect?
  code=<auth_code>&
  state=<state>
```

### 5. Token Exchange
TAK Server exchanges authorization code for access token:
```bash
POST https://account.tak.nz/application/o/token/
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&
code=<auth_code>&
client_id=<client_id>&
client_secret=<client_secret>&
redirect_uri=https://ops.tak.nz/login/redirect
```

### 6. User Info Retrieval
TAK Server retrieves user information using access token:
```bash
GET https://account.tak.nz/application/o/userinfo/
Authorization: Bearer <access_token>
```

### 7. Session Creation
TAK Server creates authenticated session for WebTAK access

## Security Features

### Certificate Validation
- **TrustAllCerts**: Configurable certificate validation for development
- **Production**: Full certificate chain validation required
- **Development**: Can disable certificate validation for testing

### Token Security
- **JWT Tokens**: Signed JSON Web Tokens for secure authentication
- **Short Expiry**: Tokens have limited lifetime for security
- **Refresh Tokens**: Automatic token refresh for seamless experience

### Access Control
- **LDAP Groups**: Integration with LDAP group membership
- **Group Prefix**: Configurable group prefix for organization
- **Role Mapping**: LDAP roles mapped to TAK Server permissions

## Deployment

### Prerequisites
1. **AuthInfra Stack**: Must be deployed first for Authentik integration
2. **LDAP Configuration**: Authentik must be configured with LDAP backend
3. **Domain Setup**: DNS records must point to load balancer

### Deployment Commands
```bash
# Deploy with OIDC enabled
npm run deploy:dev

# Deploy with custom configuration
npm run deploy:dev -- \
  --context webtak.applicationName="Custom WebTAK" \
  --context webtak.groupName="Custom Group"
```

### Verification
1. **Check Lambda Logs**: Verify OIDC setup completed successfully
2. **Test Authentication**: Access WebTAK URL and verify redirect to Authentik
3. **Validate Tokens**: Check JWT token structure and claims
4. **Group Access**: Verify LDAP group membership controls access

## Troubleshooting

### Common Issues

#### **OIDC Setup Failed**
```
Error: Failed to create OIDC application in Authentik
```
**Solutions:**
- Verify Authentik admin credentials in Secrets Manager
- Check Lambda function logs for detailed error messages
- Ensure Authentik is accessible from Lambda function
- Validate Authentik API endpoints

#### **Authentication Redirect Loop**
```
User gets stuck in redirect loop between TAK Server and Authentik
```
**Solutions:**
- Verify redirect URIs match exactly (including ports)
- Check client ID and secret configuration
- Validate OAuth flow configuration in Authentik
- Ensure TAK Server can reach Authentik token endpoint

#### **Access Denied After Authentication**
```
User authenticates successfully but cannot access WebTAK
```
**Solutions:**
- Verify user is member of configured LDAP group
- Check LDAP group name matches `groupName` configuration
- Validate LDAP group prefix configuration
- Review TAK Server logs for authorization errors

#### **Certificate Validation Errors**
```
SSL certificate verification failed
```
**Solutions:**
- Set `TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts: 'true'` for development
- Ensure proper SSL certificates for production
- Verify certificate chain is complete
- Check certificate expiration dates

### Debug Commands

```bash
# Check OIDC setup Lambda logs
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/TAK-Dev-TakInfra-WebTakOidcSetup"

# View TAK Server container logs
aws logs describe-log-groups --log-group-name-prefix "/ecs/TAK-Dev-TakInfra"

# Test OIDC endpoints
curl -v "https://account.tak.nz/.well-known/openid_configuration"

# Validate JWT token (decode only, don't verify signature)
echo "<jwt_token>" | cut -d. -f2 | base64 -d | jq .
```

### Configuration Validation

```bash
# Verify WebTAK configuration
npm run synth:dev | grep -A 20 "WebTakOidcSetup"

# Check environment variables
npm run synth:dev | grep -A 10 "TAKSERVER_CoreConfig_OAuth"

# Validate redirect URIs
npm run synth:dev | grep "REDIRECT_URIS"
```

## Advanced Configuration

### Custom Authentication Flows
Configure custom Authentik flows for specific requirements:

```json
{
  "webtak": {
    "authenticationFlowName": "custom-webtak-auth-flow",
    "authorizationFlowName": "custom-webtak-authz-flow",
    "invalidationFlowName": "custom-webtak-logout-flow"
  }
}
```

### Multiple Redirect URIs
The system automatically configures both standard and port-specific redirect URIs:
- `https://ops.tak.nz:8446/login/redirect` (WebTAK admin port)
- `https://ops.tak.nz/login/redirect` (Standard HTTPS port)

### Group-Based Access Control
Configure LDAP group integration:

```json
{
  "webtak": {
    "groupName": "WebTAK Users",
    "description": "Access to WebTAK interface"
  },
  "takserver": {
    "ldapGroupPrefix": "tak_"
  }
}
```

### Custom Branding
Configure application appearance in Authentik:

```json
{
  "webtak": {
    "applicationName": "Enterprise WebTAK",
    "description": "Enterprise geospatial collaboration platform",
    "iconPath": "assets/custom-logo.png",
    "openInNewTab": false
  }
}
```

## Security Best Practices

### Production Configuration
- **Certificate Validation**: Always enable full certificate validation
- **Secure Secrets**: Use AWS Secrets Manager for all sensitive data
- **Group Restrictions**: Limit access to specific LDAP groups
- **Token Expiry**: Configure appropriate token lifetimes
- **Audit Logging**: Enable comprehensive audit logging

### Development Configuration
- **Certificate Flexibility**: Can disable certificate validation for testing
- **Extended Logging**: Enable detailed logging for troubleshooting
- **Test Groups**: Use separate LDAP groups for development access

### Network Security
- **Private Subnets**: All components deployed in private subnets
- **Security Groups**: Restrictive network access controls
- **Load Balancer**: Network Load Balancer for TAK protocols
- **VPC Integration**: Secure VPC networking with base infrastructure

## Monitoring and Logging

### CloudWatch Metrics
- **Authentication Success/Failure**: Track authentication attempts
- **Token Exchange**: Monitor token exchange operations
- **User Sessions**: Track active user sessions
- **Error Rates**: Monitor authentication error rates

### Log Analysis
```bash
# Authentication events
aws logs filter-log-events \
  --log-group-name "/ecs/TAK-Dev-TakInfra" \
  --filter-pattern "OAuth"

# OIDC setup events
aws logs filter-log-events \
  --log-group-name "/aws/lambda/TAK-Dev-TakInfra-WebTakOidcSetup" \
  --filter-pattern "ERROR"
```

### Performance Monitoring
- **Response Times**: Monitor authentication flow performance
- **Token Validation**: Track token validation latency
- **User Experience**: Monitor end-to-end authentication time

## Migration and Upgrades

### Enabling OIDC on Existing Deployment
1. Update `cdk.json` with WebTAK OIDC configuration
2. Deploy infrastructure changes: `npm run deploy:dev`
3. Verify OIDC setup in Authentik admin interface
4. Test authentication flow with test user
5. Update user documentation and training

### Disabling OIDC
1. Set `enableOidc: false` in `cdk.json`
2. Deploy changes: `npm run deploy:dev`
3. OAuth configuration will be removed from TAK Server
4. Users will fall back to LDAP authentication

### Version Upgrades
- **TAK Server**: OIDC configuration persists across TAK Server version upgrades
- **Authentik**: Verify compatibility with Authentik version upgrades
- **Infrastructure**: Test OIDC functionality after infrastructure updates