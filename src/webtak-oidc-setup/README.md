# WebTAK OIDC Setup

This Lambda function sets up an OIDC provider and application in Authentik for WebTAK authentication.

## Overview

The function performs the following tasks:
1. Creates or updates an OAuth2 provider in Authentik for WebTAK
2. Creates or updates a WebTAK application in Authentik
3. Sets up required scope mappings for OpenID Connect (email, openid, profile)
4. Uploads TAK logo as application icon
5. Assigns application to specified Authentik group
6. Retrieves OIDC configuration endpoints
7. Returns client credentials and endpoint URLs

## OIDC Configuration

The function returns the following OIDC configuration values needed for WebTAK authentication:

| Value | Description | Example |
|-------|-------------|---------|
| `issuer` | OpenID Configuration Issuer | `https://account.tak.nz/application/o/tak-webtak/` |
| `authorizeUrl` | Authorization endpoint | `https://account.tak.nz/application/o/authorize/` |
| `tokenUrl` | Token endpoint | `https://account.tak.nz/application/o/token/` |
| `userInfoUrl` | User info endpoint | `https://account.tak.nz/application/o/userinfo/` |
| `jwksUri` | JSON Web Key Set URI | `https://account.tak.nz/application/o/jwks/` |
| `clientId` | OAuth2 client ID | `abcdef123456` |
| `clientSecret` | OAuth2 client secret | `********` |

## Testing

To test the function locally:

1. Install dependencies:
   ```bash
   npm install
   ```

2. Create a `.env` file with the required environment variables:
   ```bash
   AUTHENTIK_URL=https://account.tak.nz
   AUTHENTIK_ADMIN_TOKEN=your_admin_token_here
   PROVIDER_NAME=TAK-WebTAK
   APPLICATION_NAME=WebTAK
   APPLICATION_SLUG=tak-webtak
   REDIRECT_URIS=["https://ops.tak.nz/login/redirect"]
   LAUNCH_URL=https://ops.tak.nz
   OPEN_IN_NEW_TAB=true
   APPLICATION_DESCRIPTION=Web-based geospatial collaboration platform (Legacy system).
   GROUP_NAME=Team Awareness Kit
   LDAP_GROUP_PREFIX=tak_
   ```

3. Run `node test-local.js` to test the full function

> **Note:** The `.env` file is only used for local testing and is excluded from the Lambda deployment package. Environment variables for the Lambda function are set through the CDK construct.

## Environment Variables

| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| `AUTHENTIK_URL` | Authentik base URL | Yes | - |
| `AUTHENTIK_ADMIN_TOKEN` | Admin API token (local testing only) | Yes | - |
| `AUTHENTIK_ADMIN_SECRET_ARN` | Admin secret ARN (Lambda only) | Yes | - |
| `PROVIDER_NAME` | OAuth2 provider name | Yes | `TAK-WebTAK` |
| `APPLICATION_NAME` | Application display name | Yes | `WebTAK` |
| `APPLICATION_SLUG` | Application URL slug | Yes | `tak-webtak` |
| `REDIRECT_URIS` | JSON array of redirect URIs | Yes | - |
| `LAUNCH_URL` | Application launch URL | Yes | - |
| `OPEN_IN_NEW_TAB` | Open in new tab (true/false) | No | `true` |
| `APPLICATION_DESCRIPTION` | Application description | No | - |
| `AUTHENTICATION_FLOW_NAME` | Authentication flow name | No | - |
| `AUTHORIZATION_FLOW_NAME` | Authorization flow name | No | `default-provider-authorization-implicit-consent` |
| `INVALIDATION_FLOW_NAME` | Invalidation flow name | No | `default-provider-invalidation-flow` |
| `GROUP_NAME` | Authentik group to assign | No | - |
| `LDAP_GROUP_PREFIX` | LDAP group prefix for filtering | No | - |

## WebTAK Integration

The redirect URI is configured as `{webTakUrl}/login/redirect` where `webTakUrl` is the TAK Service URL (same as the TAK Server endpoint). This allows WebTAK to handle OIDC authentication callbacks properly.

## Cleanup

When the CloudFormation stack is deleted, the function automatically cleans up:
- Removes the WebTAK application from Authentik
- Removes the OAuth2 provider from Authentik