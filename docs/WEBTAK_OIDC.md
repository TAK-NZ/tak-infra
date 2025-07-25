# WebTAK OIDC Integration

This document describes the WebTAK OIDC (OpenID Connect) integration feature that automatically sets up authentication between WebTAK and Authentik.

## Overview

The WebTAK OIDC setup automatically creates:
- An OIDC provider in Authentik for WebTAK authentication
- An application in Authentik for WebTAK
- Required scope mappings (email, openid, profile)
- Proper redirect URIs and configuration

## Configuration

WebTAK OIDC is configured in the `webtak` section of `cdk.json`:

```json
{
  "context": {
    "dev-test": {
      "webtak": {
        "enableOidc": true,
        "providerName": "TAK-WebTAK",
        "applicationName": "WebTAK",
        "applicationSlug": "tak-webtak",
        "openInNewTab": true,
        "authenticationFlowName": "",
        "authorizationFlowName": "default-provider-authorization-implicit-consent",
        "invalidationFlowName": "default-provider-invalidation-flow",
        "groupName": "Team Awareness Kit",
        "description": "Web-based geospatial collaboration platform (Legacy system).",
        "iconPath": "src/webtak-oidc-setup/tak-logo.png"
      }
    }
  }
}
```

### Configuration Options

| Option | Description | Default |
|--------|-------------|----------|
| `enableOidc` | Enable WebTAK OIDC setup | `false` |
| `providerName` | Name of the OIDC provider in Authentik | `TAK-WebTAK` |
| `applicationName` | Display name of the application | `WebTAK` |
| `applicationSlug` | URL slug for the application | `tak-webtak` |
| `openInNewTab` | Open application in new tab | `true` |
| `authenticationFlowName` | Custom authentication flow (optional) | |
| `authorizationFlowName` | Authorization flow to use | `default-provider-authorization-implicit-consent` |
| `invalidationFlowName` | Invalidation flow to use | `default-provider-invalidation-flow` |
| `groupName` | Authentik group to assign to application | `Team Awareness Kit` |
| `description` | Application description | `Web-based geospatial collaboration platform (Legacy system).` |
| `iconPath` | Path to application icon file | `src/webtak-oidc-setup/tak-logo.png` |

## Prerequisites

The WebTAK OIDC setup requires:
1. **AuthInfra stack** deployed with Authentik
2. **Authentik admin secret** exported from AuthInfra
3. **Authentik URL** exported from AuthInfra

## How It Works

When `webtak.enableOidc` is enabled, the stack:

1. **Imports required resources** from AuthInfra:
   - Authentik admin secret ARN
   - Authentik URL

2. **Creates Lambda function** that:
   - Connects to Authentik API using admin credentials
   - Creates/updates OAuth2 provider with name "WebTAK OIDC Provider"
   - Creates/updates application with slug "webtak"
   - Sets up redirect URI: `https://webtak.{domain}/oauth2/idpresponse`
   - Configures required OIDC scopes and flows

3. **Exports OIDC configuration** as CloudFormation outputs:
   - Client ID
   - Issuer URL
   - Authorization URL

## Stack Outputs

When WebTAK OIDC is enabled, the following outputs are available:

| Output | Description | Export Name |
|--------|-------------|-------------|
| `WebTakOidcClientId` | OIDC Client ID for WebTAK | `{StackName}-WebTakOidcClientId` |
| `WebTakOidcIssuer` | OIDC Issuer URL | `{StackName}-WebTakOidcIssuer` |
| `WebTakOidcAuthorizeUrl` | OIDC Authorization URL | `{StackName}-WebTakOidcAuthorizeUrl` |

## Usage in CloudTAK

The CloudTAK stack can import these values to configure WebTAK authentication:

```typescript
// Import OIDC configuration from TakInfra
const webTakOidcClientId = Fn.importValue(`TAK-${environment}-TakInfra-WebTakOidcClientId`);
const webTakOidcIssuer = Fn.importValue(`TAK-${environment}-TakInfra-WebTakOidcIssuer`);
```

## Authentik Configuration

The Lambda function automatically configures:

- **Provider Name**: "TAK-WebTAK" (configurable)
- **Application Name**: "WebTAK" (configurable)
- **Application Slug**: "tak-webtak" (configurable)
- **Client Type**: Confidential
- **Redirect URI**: `https://webtak.{domain}/oauth2/idpresponse`
- **Scopes**: email, openid, profile
- **Flows**: Configurable authentication, authorization, and invalidation flows
- **Group Assignment**: Assigns application to specified Authentik group
- **Icon**: Uploads TAK logo as application icon

## Troubleshooting

### Common Issues

1. **Missing AuthInfra exports**: Ensure AuthInfra stack exports `AuthentikAdminTokenArn` and `AuthentikUrl`
2. **Lambda timeout**: The Lambda has a 10-minute timeout for Authentik API operations
3. **Authentik API errors**: Check Lambda logs in CloudWatch for detailed error messages

### Debugging

Check the Lambda function logs in CloudWatch:
```bash
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/TAK-{Environment}-TakInfra-WebTakOidcSetup"
```

### Manual Cleanup

If needed, you can manually clean up Authentik resources:
1. Delete the "webtak" application in Authentik admin interface
2. Delete the "WebTAK OIDC Provider" OAuth2 provider

## Security Considerations

- **Client Secret**: Automatically generated and managed by Authentik
- **Scope Limitations**: Only email, openid, and profile scopes are configured
- **Redirect URI Validation**: Strict matching mode for redirect URIs
- **Token Validity**: Short-lived access tokens (5 minutes) with longer refresh tokens (30 days)