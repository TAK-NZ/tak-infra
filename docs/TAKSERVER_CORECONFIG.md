# TAK Server CoreConfig Environment Variable System

## Overview

TAK Server supports dynamic configuration through environment variables that override XML configuration values. This system allows runtime configuration changes without modifying XML files, making it ideal for containerized deployments and CI/CD pipelines.

## Environment Variable System

### Case Sensitivity Requirements

Environment variables **must match the exact case** of the XML Schema Definition (XSD). TAK Server performs case-sensitive matching against the CoreConfig XSD, and variables with incorrect case will be **silently ignored**.

### Naming Convention

```
TAKSERVER_CoreConfig_{XmlPath}_{AttributeName}
```

- **TAKSERVER_CoreConfig**: Fixed prefix (case-sensitive)
- **{XmlPath}**: XML element path using exact XSD case
- **{AttributeName}**: XML attribute name using exact XSD case

### Examples

#### ✅ Correct - Matches XSD Exactly
```bash
# Authentication settings
TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive="true"

# Network connector settings
TAKSERVER_CoreConfig_Network_Connector_8443_AllowOrigins="https://app.com,https://admin.com"

# Federation settings
TAKSERVER_CoreConfig_Federation_EnableFederation="true"

# Repository settings
TAKSERVER_CoreConfig_Repository_Archive="false"
```

#### ❌ Wrong - Case Mismatch Will Be Ignored
```bash
# All lowercase - will be ignored
takserver_coreconfig_auth_x509usegroupcache="true"

# All uppercase - will be ignored
TAKSERVER_CORECONFIG_AUTH_X509USEGROUPCACHE="true"

# Inconsistent case - will be ignored
TAKSERVER_CoreConfig_auth_X509UseGroupCache="true"
```

## Configuration Categories

### Network Connector Configuration

Network connectors define HTTP/HTTPS endpoints that TAK Server exposes for web-based access. Each connector represents a separate port with its own security settings, authentication requirements, and feature enablement flags.

#### Core Connection Settings

**Port Configuration**
```bash
# Set connector port
TAKSERVER_CoreConfig_Network_Connector_8443_Port="8443"

# Enable/disable TLS
TAKSERVER_CoreConfig_Network_Connector_8443_Tls="true"

# Set connector name
TAKSERVER_CoreConfig_Network_Connector_8443_Name="main_https"
```

**TLS/SSL Configuration**
```bash
# Client certificate authentication
TAKSERVER_CoreConfig_Network_Connector_8443_ClientAuth="true"

# Keystore configuration
TAKSERVER_CoreConfig_Network_Connector_8443_Keystore="JKS"
TAKSERVER_CoreConfig_Network_Connector_8443_KeystoreFile="/opt/tak/certs/takserver.jks"
TAKSERVER_CoreConfig_Network_Connector_8443_KeystorePass="atakatak"

# Truststore configuration
TAKSERVER_CoreConfig_Network_Connector_8443_Truststore="JKS"
TAKSERVER_CoreConfig_Network_Connector_8443_TruststoreFile="/opt/tak/certs/truststore-root.jks"
TAKSERVER_CoreConfig_Network_Connector_8443_TruststorePass="atakatak"
```

**Authentication Settings**
```bash
# Enable HTTP Basic Authentication for specific endpoints
TAKSERVER_CoreConfig_Network_Connector_8446_AllowBasicAuth="true"
```

**Feature Enablement**
```bash
# Enable administrative web interface access
TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI="true"

# Enable WebTAK (web-based TAK client) access
TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak="true"

# Enable non-administrative web interface access
TAKSERVER_CoreConfig_Network_Connector_8443_EnableNonAdminUI="true"
```

**CORS (Cross-Origin Resource Sharing) Settings**
```bash
# Allowed origins for CORS requests
TAKSERVER_CoreConfig_Network_Connector_8443_AllowOrigins="https://app.com,https://admin.com"

# HTTP methods allowed for CORS requests
TAKSERVER_CoreConfig_Network_Connector_8443_AllowMethods="POST, PUT, GET, HEAD, OPTIONS, DELETE"

# HTTP headers allowed for CORS requests
TAKSERVER_CoreConfig_Network_Connector_8443_AllowHeaders="Accept, Authorization, Content-Type, Cookie, Origin"

# Allow credentials in CORS requests
TAKSERVER_CoreConfig_Network_Connector_8443_AllowCredentials="true"
```

### X.509 Group Cache Configuration

The X.509 group cache system provides advanced group management capabilities for certificate-based authentication, allowing users to have "active" and "inactive" groups.

```bash
# Enable/disable the entire group caching system
TAKSERVER_CoreConfig_Auth_X509useGroupCache="true"

# New users' first groups marked as "active" by default
TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive="false"

# Newly added groups for existing users marked as "active" by default
TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultUpdatesActive="false"

# Require users to have at least one active group
TAKSERVER_CoreConfig_Auth_X509useGroupCacheRequiresActiveGroup="true"

# Require specific Extended Key Usage attributes in certificates
TAKSERVER_CoreConfig_Auth_X509useGroupCacheRequiresExtKeyUsage="true"
```

**Use Cases:**
- **Enterprise Deployments**: Users belong to many groups but only need access to specific subsets at different times
- **Security-Conscious Environments**: Selective group activation reduces attack surface
- **Dynamic Group Management**: Change group access without re-authentication

### LDAP Authentication Configuration

LDAP authentication enables TAK Server to authenticate users against Active Directory (AD) or other LDAP-compliant directory services.

**Core Connection Settings**
```bash
# LDAP server URL
TAKSERVER_CoreConfig_Auth_Ldap_Url="ldaps://ldap.example.com:636"

# User DN template
TAKSERVER_CoreConfig_Auth_Ldap_Userstring="{username}@domain.com"

# Service account for LDAP operations
TAKSERVER_CoreConfig_Auth_Ldap_ServiceAccountDN="cn=takserver,ou=service accounts,dc=example,dc=com"
TAKSERVER_CoreConfig_Auth_Ldap_ServiceAccountCredential="password123"
```

**Directory Structure Settings**
```bash
# Directory style (AD or DS)
TAKSERVER_CoreConfig_Auth_Ldap_Style="AD"

# Base DNs for searches
TAKSERVER_CoreConfig_Auth_Ldap_GroupBaseRDN="ou=groups,dc=example,dc=com"
TAKSERVER_CoreConfig_Auth_Ldap_UserBaseRDN="ou=users,dc=example,dc=com"

# Object classes
TAKSERVER_CoreConfig_Auth_Ldap_GroupObjectClass="group"
TAKSERVER_CoreConfig_Auth_Ldap_UserObjectClass="user"
```

**Group Processing Settings**
```bash
# Group name prefix filter
TAKSERVER_CoreConfig_Auth_Ldap_Groupprefix="tak_"

# Group name extraction regex
TAKSERVER_CoreConfig_Auth_Ldap_GroupNameExtractorRegex="CN=(.*?)(?:,|$)"

# Read-only group settings
TAKSERVER_CoreConfig_Auth_Ldap_ReadOnlyGroup="TAK_ReadOnly"
TAKSERVER_CoreConfig_Auth_Ldap_ReadGroupSuffix="_READ"
TAKSERVER_CoreConfig_Auth_Ldap_WriteGroupSuffix="_WRITE"
```

**Advanced Group Features**
```bash
# Enable recursive nested group membership lookup
TAKSERVER_CoreConfig_Auth_Ldap_NestedGroupLookup="true"

# Use AD-specific group chain matching
TAKSERVER_CoreConfig_Auth_Ldap_MatchGroupInChain="true"
```

**Security Settings**
```bash
# LDAP authentication security type
TAKSERVER_CoreConfig_Auth_Ldap_LdapSecurityType="simple"

# LDAPS truststore configuration
TAKSERVER_CoreConfig_Auth_Ldap_LdapsTruststore="JKS"
TAKSERVER_CoreConfig_Auth_Ldap_LdapsTruststoreFile="/opt/tak/certs/ldaps-truststore.jks"
TAKSERVER_CoreConfig_Auth_Ldap_LdapsTruststorePass="truststore_password"
```

**X.509 Integration Settings**
```bash
# Enable LDAP group lookup for X.509 authenticated users
TAKSERVER_CoreConfig_Auth_Ldap_X509groups="true"

# Add anonymous group to X.509 users with LDAP groups
TAKSERVER_CoreConfig_Auth_Ldap_X509addAnonymous="false"
```

### OAuth Authentication Configuration

OAuth authentication enables TAK Server to integrate with external identity providers (IdPs) such as Keycloak, Azure AD, or Okta.

**Global OAuth Settings**
```bash
# Add anonymous group to OAuth users without explicit groups
TAKSERVER_CoreConfig_Auth_Oauth_OauthAddAnonymous="false"

# Enable group caching for OAuth authenticated users
TAKSERVER_CoreConfig_Auth_Oauth_OauthUseGroupCache="false"

# Group name prefix filter
TAKSERVER_CoreConfig_Auth_Oauth_Groupprefix="tak_"

# Read-only group settings
TAKSERVER_CoreConfig_Auth_Oauth_ReadOnlyGroup="TAK_ReadOnly"
TAKSERVER_CoreConfig_Auth_Oauth_ReadGroupSuffix="_READ"
TAKSERVER_CoreConfig_Auth_Oauth_WriteGroupSuffix="_WRITE"
```

**JWT Claims Configuration**
```bash
# JWT claim name containing user's group memberships
TAKSERVER_CoreConfig_Auth_Oauth_GroupsClaim="groups"

# JWT claim name containing username
TAKSERVER_CoreConfig_Auth_Oauth_UsernameClaim="preferred_username"

# JWT claim name containing OAuth scopes
TAKSERVER_CoreConfig_Auth_Oauth_ScopeClaim="scope"

# Required OAuth scope for WebTAK access
TAKSERVER_CoreConfig_Auth_Oauth_WebtakScope="webtak"
```

**UI Integration Settings**
```bash
# Use TAK Server's login page instead of external IdP
TAKSERVER_CoreConfig_Auth_Oauth_UseTakServerLoginPage="false"

# Allow login using email address as username
TAKSERVER_CoreConfig_Auth_Oauth_LoginWithEmail="false"

# Allow OAuth tokens in URI query parameters (less secure)
TAKSERVER_CoreConfig_Auth_Oauth_AllowUriQueryParameter="false"
```

**OAuth Authorization Server Configuration**

OAuth authorization servers define external identity providers that TAK Server can authenticate against. Each server requires specific configuration:

**Automatic Public Key Download:**
TAK Server can automatically download the issuer's public key from the JWKS endpoint using the `getOIDCIssuerPubKey.sh` script. When `TAKSERVER_CoreConfig_OAuthServer_JWKS` is configured, the script will:
1. Fetch the JWKS data from the specified URL
2. Extract the x5c certificate value
3. Convert it to the proper format for TAK Server
4. Save it to the path specified in `TAKSERVER_CoreConfig_OAuthServer_Issuer`

```bash
# Authorization server name (identifier)
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_Name="keycloak"

# OAuth issuer certificate file path (not URL)
TAKSERVER_CoreConfig_OAuthServer_Issuer="/opt/tak/certs/files/oauth-public-key.pem"

# OAuth JWKS URL for automatic public key download
TAKSERVER_CoreConfig_OAuthServer_JWKS="https://keycloak.example.com/auth/realms/tak/protocol/openid-connect/certs"

# OAuth client identifier
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_ClientId="takserver"

# OAuth client secret
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_Secret="your-client-secret"

# OAuth redirect URI for authorization code flow
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_RedirectUri="https://takserver.example.com:8443/oauth/login/redirect"

# OAuth authorization endpoint URL
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_AuthEndpoint="https://keycloak.example.com/auth/realms/tak/protocol/openid-connect/auth"

# OAuth token endpoint URL
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_TokenEndpoint="https://keycloak.example.com/auth/realms/tak/protocol/openid-connect/token"

# OAuth scopes to request
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_Scope="openid profile email groups"

# Access token field name in response
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_AccessTokenName="access_token"

# Refresh token field name in response
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_RefreshTokenName="refresh_token"

# Disable SSL certificate validation (development only)
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Keycloak_TrustAllCerts="false"
```

**Common IdP Examples:**

*Azure Active Directory:*
```bash
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_AzureAD_Name="azure-ad"
TAKSERVER_CoreConfig_OAuthServer_Issuer="/opt/tak/certs/files/azure-ad-public-key.pem"
TAKSERVER_CoreConfig_OAuthServer_JWKS="https://login.microsoftonline.com/tenant-id/discovery/v2.0/keys"
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_AzureAD_ClientId="your-azure-client-id"
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_AzureAD_AuthEndpoint="https://login.microsoftonline.com/tenant-id/oauth2/v2.0/authorize"
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_AzureAD_TokenEndpoint="https://login.microsoftonline.com/tenant-id/oauth2/v2.0/token"
```

*Okta:*
```bash
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Okta_Name="okta"
TAKSERVER_CoreConfig_OAuthServer_Issuer="/opt/tak/certs/files/okta-public-key.pem"
TAKSERVER_CoreConfig_OAuthServer_JWKS="https://dev-123456.okta.com/oauth2/default/v1/keys"
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Okta_ClientId="your-okta-client-id"
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Okta_AuthEndpoint="https://dev-123456.okta.com/oauth2/default/v1/authorize"
TAKSERVER_CoreConfig_Auth_Oauth_AuthServer_Okta_TokenEndpoint="https://dev-123456.okta.com/oauth2/default/v1/token"
```

### Federation Configuration

```bash
# Enable/disable federation
TAKSERVER_CoreConfig_Federation_EnableFederation="true"

# Federation port
TAKSERVER_CoreConfig_Federation_FederationPort="9000"

# Allow federation without client certificate
TAKSERVER_CoreConfig_Federation_AllowFederationWithoutClientCert="false"
```

### Repository Configuration

```bash
# Enable/disable data archiving
TAKSERVER_CoreConfig_Repository_Archive="false"

# Archive connection pool size
TAKSERVER_CoreConfig_Repository_ArchiveConnectionPoolSize="4"

# Enable automatic mission archiving
TAKSERVER_CoreConfig_Repository_ArchiveAutomaticMissionDisabled="false"
```

### CloudWatch Metrics Configuration

```bash
# Enable CloudWatch metrics
TAKSERVER_CoreConfig_Network_CloudwatchEnable="true"

# CloudWatch metrics interval (seconds)
TAKSERVER_CoreConfig_Network_CloudwatchInterval="30"

# CloudWatch namespace for metrics
TAKSERVER_CoreConfig_Network_CloudwatchNamespace="takserver"

# CloudWatch metrics batch size
TAKSERVER_CoreConfig_Network_CloudwatchMetricsBatchSize="20"

# CloudWatch name identifier
TAKSERVER_CoreConfig_Network_CloudwatchName="tak-server-instance"
```

### Network Performance Configuration

```bash
# Use Linux epoll for improved network performance (Linux only)
TAKSERVER_CoreConfig_Network_UseLinuxEpoll="true"

# HTTP session timeout in minutes (default: 130)
TAKSERVER_CoreConfig_Network_HttpSessionTimeoutMinutes="130"

# Allow CORS requests from all origins (security risk if enabled)
TAKSERVER_CoreConfig_Network_AllowAllOrigins="false"

# Enable HTTP Strict Transport Security headers for enhanced security
TAKSERVER_CoreConfig_Network_EnableHSTS="true"

# Comma-separated list of allowed TLS cipher suites for web connections
TAKSERVER_CoreConfig_Network_WebCiphers="TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"

# Multicast TTL for network packets (default: 1)
TAKSERVER_CoreConfig_Network_MulticastTTL="1"

# Unique identifier for this TAK Server instance
TAKSERVER_CoreConfig_Network_ServerId="tak-server-01"

# Hostname or IP address of the TAK Server
TAKSERVER_CoreConfig_Network_TakServerHost="takserver.example.com"

# Directory for external web content (default: webcontent)
TAKSERVER_CoreConfig_Network_ExtWebContentDir="webcontent"
```

### Buffer and Queue Configuration

```bash
# Publish/subscribe queue capacity (default: 512)
TAKSERVER_CoreConfig_Buffer_PubSubCapacity="512"

# Inbound message queue capacity (default: 4096)
TAKSERVER_CoreConfig_Buffer_InboundCapacity="4096"

# Outbound message queue capacity (default: 4)
TAKSERVER_CoreConfig_Buffer_OutboundCapacity="4"

# TCP write queue capacity (default: 32768)
TAKSERVER_CoreConfig_Buffer_TcpWriteQueueCapacity="32768"

# Disconnect clients when queues are full (prevents memory issues)
TAKSERVER_CoreConfig_Buffer_DisconnectOnFull="false"

# Queue flush interval in milliseconds (default: 1000)
TAKSERVER_CoreConfig_Buffer_FlushInterval="1000"

# WebSocket send buffer size limit in bytes (default: 65536)
TAKSERVER_CoreConfig_Buffer_WebsocketSendBufferSizeLimit="65536"

# Maximum WebSocket binary message buffer size (default: 65536)
TAKSERVER_CoreConfig_Buffer_WebsocketMaxBinaryMessageBufferSize="65536"

# WebSocket session idle timeout in milliseconds (-1 for default)
TAKSERVER_CoreConfig_Buffer_WebsocketMaxSessionIdleTimeout="-1"

# WebSocket send timeout in milliseconds (default: 5000)
TAKSERVER_CoreConfig_Buffer_WebsocketSendTimeoutMs="5000"
```

### Database Repository Configuration

```bash
# Enable repository service (default: true)
TAKSERVER_CoreConfig_Repository_Enable="true"

# Number of database connections in pool (default: 200)
TAKSERVER_CoreConfig_Repository_NumDbConnections="200"

# Automatically size connection pool based on system resources
TAKSERVER_CoreConfig_Repository_ConnectionPoolAutoSize="true"

# Database operation timeout in milliseconds (default: 60000)
TAKSERVER_CoreConfig_Repository_DbTimeoutMs="60000"

# Maximum database connection lifetime in milliseconds (default: 600000)
TAKSERVER_CoreConfig_Repository_DbConnectionMaxLifetimeMs="600000"

# Maximum database connection idle time in milliseconds (default: 10000)
TAKSERVER_CoreConfig_Repository_DbConnectionMaxIdleMs="10000"

# Enable message archiving to database (default: false)
TAKSERVER_CoreConfig_Repository_Archive="false"

# Enable callsign auditing (default: true)
TAKSERVER_CoreConfig_Repository_EnableCallsignAudit="true"

# Batch size for primary key operations (default: 500)
TAKSERVER_CoreConfig_Repository_PrimaryKeyBatchSize="500"

# Batch size for database insertions (default: 500)
TAKSERVER_CoreConfig_Repository_InsertionBatchSize="500"

# Database connection URL (default: jdbc:postgresql://127.0.0.1:5432/cot)
TAKSERVER_CoreConfig_Repository_Connection_Url="jdbc:postgresql://127.0.0.1:5432/cot"

# Database username (default: martiuser)
TAKSERVER_CoreConfig_Repository_Connection_Username="martiuser"

# Database password
TAKSERVER_CoreConfig_Repository_Connection_Password="password"

# Enable SSL for database connections (default: false)
TAKSERVER_CoreConfig_Repository_Connection_SslEnabled="false"

# SSL mode for database connections (default: verify-ca)
TAKSERVER_CoreConfig_Repository_Connection_SslMode="verify-ca"

# SSL certificate file path for database
TAKSERVER_CoreConfig_Repository_Connection_SslCert="/opt/tak/certs/db-client.crt"

# SSL private key file path for database
TAKSERVER_CoreConfig_Repository_Connection_SslKey="/opt/tak/certs/db-client.key"

# SSL root certificate file path for database
TAKSERVER_CoreConfig_Repository_Connection_SslRootCert="/opt/tak/certs/db-ca.crt"
```

### Security and TLS Configuration

```bash
# TLS keystore type (JKS, PKCS12)
TAKSERVER_CoreConfig_Security_Tls_Keystore="JKS"

# Path to keystore file containing server certificates
TAKSERVER_CoreConfig_Security_Tls_KeystoreFile="/opt/tak/certs/takserver.jks"

# Keystore password for accessing private keys
TAKSERVER_CoreConfig_Security_Tls_KeystorePass="atakatak"

# Truststore type for client certificate validation
TAKSERVER_CoreConfig_Security_Tls_Truststore="JKS"

# Path to truststore file containing trusted CA certificates
TAKSERVER_CoreConfig_Security_Tls_TruststoreFile="/opt/tak/certs/truststore-root.jks"

# Truststore password for accessing trusted certificates
TAKSERVER_CoreConfig_Security_Tls_TruststorePass="atakatak"

# TLS context version (default: TLSv1.2)
TAKSERVER_CoreConfig_Security_Tls_Context="TLSv1.2"

# Allowed cipher suites for TLS connections
TAKSERVER_CoreConfig_Security_Tls_Ciphers="TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"

# Key manager algorithm (default: SunX509)
TAKSERVER_CoreConfig_Security_Tls_Keymanager="SunX509"

# Enable OCSP certificate validation (default: false)
TAKSERVER_CoreConfig_Security_Tls_EnableOCSP="false"

# OCSP responder URL for certificate validation
TAKSERVER_CoreConfig_Security_Tls_ResponderUrl="http://ocsp.example.com"
```

### Mission and Enterprise Sync Configuration

```bash
# Maximum number of UIDs per mission (default: 8192)
TAKSERVER_CoreConfig_Buffer_MissionUidLimit="8192"

# Maximum mission content items (default: 4096)
TAKSERVER_CoreConfig_Buffer_MissionContentLimit="4096"

# Maximum concurrent mission downloads
TAKSERVER_CoreConfig_Buffer_MissionConcurrentDownloadLimit="10"

# Mission package auto-extract size limit in MB (default: 10)
TAKSERVER_CoreConfig_Network_MissionPackageAutoExtractSizeLimitMB="10"

# Always archive mission-related CoT messages (default: false)
TAKSERVER_CoreConfig_Network_AlwaysArchiveMissionCot="false"

# Require mission owner permissions to delete missions (default: false)
TAKSERVER_CoreConfig_Network_MissionDeleteRequiresOwner="false"

# Regex pattern for groups allowed to create missions
TAKSERVER_CoreConfig_Network_MissionCreateGroupsRegex=".*"

# Tool used for mission common operational picture (default: vbm)
TAKSERVER_CoreConfig_Network_MissionCopTool="vbm"

# Maximum file size for enterprise sync uploads in MB (default: 400)
TAKSERVER_CoreConfig_Network_EnterpriseSyncSizeLimitMB="400"

# Upload timeout for enterprise sync in milliseconds (default: 600000)
TAKSERVER_CoreConfig_Network_EnterpriseSyncSizeUploadTimeoutMillis="600000"

# Download timeout for enterprise sync in milliseconds (default: 600000)
TAKSERVER_CoreConfig_Network_EnterpriseSyncSizeDownloadTimeoutMillis="600000"

# Enable enterprise sync caching (0=disabled, 1=enabled)
TAKSERVER_CoreConfig_Network_EsyncEnableCache="0"

# Enable CoT filtering for enterprise sync (default: false)
TAKSERVER_CoreConfig_Network_EsyncEnableCotFilter="false"

# CoT filter expression for enterprise sync
TAKSERVER_CoreConfig_Network_EsyncCotFilter="type='a-f-G'"
```

### Tomcat and Performance Configuration

```bash
# Set Tomcat idle threads to configured maximum (default: true)
TAKSERVER_CoreConfig_Network_TomcatPoolIdleToMax="true"

# Explicit Tomcat thread pool size (-1 for auto-detection)
TAKSERVER_CoreConfig_Network_TomcatMaxPool="-1"

# Multiplier for auto-detected thread pool size (default: 32)
TAKSERVER_CoreConfig_Network_TomcatPoolMultiplier="32"

# Timeout for report operations in seconds
TAKSERVER_CoreConfig_Network_ReportTimeoutSeconds="300"

# Interval for checking report timeouts (default: 60)
TAKSERVER_CoreConfig_Network_ReportTimeoutCheckIntervalSeconds="60"

# Force low concurrency mode for resource-constrained environments
TAKSERVER_CoreConfig_ForceLowConcurrency="true"
```

### Cache and Performance Optimization

```bash
# Near cache maximum size (0=disabled, default: 0)
TAKSERVER_CoreConfig_Buffer_NearCacheMaxSize="0"

# CoT cache maximum size (0=disabled, default: 0)
TAKSERVER_CoreConfig_Buffer_CotCacheMaxSize="0"

# Spring cache maximum size (-1=unlimited, default: -1)
TAKSERVER_CoreConfig_Buffer_SpringCacheMaxSize="-1"

# Enable on-heap caching (default: false)
TAKSERVER_CoreConfig_Buffer_OnHeapEnabled="false"

# Enable group-based caching (default: true)
TAKSERVER_CoreConfig_Buffer_EnableCacheGroup="true"

# Enable client endpoint caching (default: true)
TAKSERVER_CoreConfig_Buffer_EnableClientEndpointCache="true"

# Rate limit for contact cache updates in seconds (default: 5)
TAKSERVER_CoreConfig_Buffer_ContactCacheUpdateRateLimitSeconds="5"

# Plugin data feed cache TTL in seconds (default: 300)
TAKSERVER_CoreConfig_Buffer_PluginDatafeedCacheSeconds="300"

# Caffeine file cache TTL in seconds (default: 120)
TAKSERVER_CoreConfig_Buffer_CaffeineFileCacheSeconds="120"
```

### Store and Forward Configuration

```bash
# Enable store and forward for chat messages (default: false)
TAKSERVER_CoreConfig_Buffer_EnableStoreForwardChat="false"

# Store and forward query buffer time in milliseconds (default: 1000)
TAKSERVER_CoreConfig_Buffer_StoreForwardQueryBufferMs="1000"

# Store and forward send buffer time in milliseconds (default: 200)
TAKSERVER_CoreConfig_Buffer_StoreForwardSendBufferMs="200"
```

### Latest Situational Awareness

```bash
# Enable latest situational awareness tracking (default: false)
TAKSERVER_CoreConfig_Buffer_LatestSA_Enable="false"

# Validate client UID for latest SA (default: false)
TAKSERVER_CoreConfig_Buffer_LatestSA_ValidateClientUid="false"
```

## Configuration Methods

TAK Server supports multiple configuration approaches:

### S3 Configuration File

For production deployments, TAK Server can load configuration from an S3 bucket (imported from BaseInfra). Upload a `takserver-config.env` file to the S3 configuration bucket to provide environment variables.

**Example**: See `takserver-config.env.example` in the repository root for a complete configuration template.

**Usage**:
1. Copy `takserver-config.env.example` to `takserver-config.env`
2. Customize the configuration values
3. Upload to the S3 bucket: `s3://{bucket-name}/takserver-config.env`
4. Enable S3 configuration in deployment: `useS3TAKServerConfigFile=true`

### Three-Tier Default System

TAK Server uses a hierarchical configuration system:

1. **XSD Defaults**: Built-in defaults from the XML Schema Definition
2. **S3 Configuration File**: Environment variables from S3 bucket (when enabled)
3. **Runtime Environment Variables**: Direct container environment variables (highest precedence)

### S3 Configuration File Example

Example `takserver-config.env` file for S3 deployment:

```bash
# Authentication settings
TAKSERVER_CoreConfig_Auth_X509useGroupCache="true"
TAKSERVER_CoreConfig_Auth_Ldap_Style="AD"
TAKSERVER_CoreConfig_Auth_Ldap_Url="ldaps://ldap.example.com:636"

# Network connector settings
TAKSERVER_CoreConfig_Network_Connector_8443_AllowOrigins="https://app.example.com"
TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak="true"

# Federation and monitoring
TAKSERVER_CoreConfig_Federation_EnableFederation="true"
TAKSERVER_CoreConfig_Network_CloudwatchEnable="true"
```

### Runtime Overrides

Environment variables always take precedence:

```bash
# Override project defaults at runtime
export TAKSERVER_CoreConfig_Auth_X509useGroupCache="false"
export TAKSERVER_CoreConfig_Network_Connector_8443_AllowOrigins="https://custom.domain.com"
```

## Best Practices

### Case Sensitivity
- Always use exact XSD case for element and attribute names
- Test environment variables in development before production deployment
- Use XML validation tools to verify XSD compliance

### Security Considerations
- Store sensitive values (passwords, secrets) in secure secret management systems
- Use environment variable injection rather than hardcoded values
- Regularly audit environment variable configurations

### Configuration Management
- Document all environment variable overrides
- Use consistent naming conventions across environments
- Implement configuration validation in deployment pipelines

### Testing
- Validate configuration changes in development environments
- Use XML schema validation to verify configuration correctness
- Monitor TAK Server logs for configuration warnings or errors

## Troubleshooting

### Common Issues

**Environment Variables Ignored**
- Check case sensitivity - variables must match XSD exactly
- Verify environment variable naming convention
- Ensure variables are properly exported in container environment

**Configuration Not Applied**
- Check TAK Server startup logs for configuration errors
- Verify XML schema validation passes
- Ensure environment variables are available to TAK Server process

**Authentication Issues**
- Verify LDAP/OAuth configuration variables are correctly set
- Check network connectivity to external authentication services
- Validate certificate and truststore configurations

### Debug Commands

```bash
# Check environment variables in container
env | grep TAKSERVER_CoreConfig

# Validate XML configuration
xmllint --schema CoreConfig.xsd --noout CoreConfig.xml

# Check TAK Server configuration logs
docker logs takserver-container | grep -i config
```

## Integration Examples

### AWS ECS Task Definition
```json
{
  "environment": [
    {
      "name": "TAKSERVER_CoreConfig_Auth_X509useGroupCache",
      "value": "true"
    },
    {
      "name": "TAKSERVER_CoreConfig_Network_Connector_8443_AllowOrigins",
      "value": "https://app.example.com"
    }
  ]
}
```