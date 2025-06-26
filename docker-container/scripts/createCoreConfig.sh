#!/bin/bash

# Get output file path (default to /opt/tak/CoreConfig.xml if not provided)
OUTPUT_FILE="${1:-/opt/tak/CoreConfig.xml}"
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Load project defaults
if [[ -f "$SCRIPT_DIR/project-defaults.env" ]]; then
    source "$SCRIPT_DIR/project-defaults.env"
fi

# Check required environment variables
for env in PostgresUsername PostgresPassword PostgresURL TAK_VERSION LDAP_DN LDAP_SECURE_URL; do
    if [[ -z "${!env}" ]]; then
        echo "${env} Environment Variable not set"
        exit 1
    fi
done

# Helper function to convert string to boolean
string_to_boolean() {
    local value="${1,,}"
    [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" ]] && echo "true" || echo "false"
}

# Get default value with project override support
get_default_value() {
    local env_path="$1"
    local xsd_default="$2"
    local project_default_var="${env_path}_DEFAULT"
    local project_default="${!project_default_var}"
    echo "${project_default:-$xsd_default}"
}

# Get environment value with defaults
get_env_value() {
    local env_path="$1"
    local xsd_default="$2"
    local type="${3:-string}"
    
    local default_value=$(get_default_value "$env_path" "$xsd_default")
    local env_value="${!env_path:-$default_value}"
    
    if [[ "$type" == "boolean" ]]; then
        string_to_boolean "$env_value"
    else
        echo "$env_value"
    fi
}

# Add attribute only if different from XSD default
add_attr() {
    local attr_name="$1"
    local value="$2"
    local xsd_default="$3"
    [[ "$value" != "$xsd_default" ]] && echo -n " $attr_name=\"$value\""
}

# Set commonly used values
LETSENCRYPT_DOMAIN=$(get_env_value "TAKSERVER_QuickConnect_LetsEncrypt_Domain" "nodomainset")
SERVER_ID=$(cat /proc/sys/kernel/random/uuid)

# Download and setup AWS Root CA
curl -s https://www.amazontrust.com/repository/AmazonRootCA1.pem > /tmp/AmazonRootCA1.pem
echo "yes" | keytool -import -file /tmp/AmazonRootCA1.pem -alias AWS -deststoretype JKS -deststorepass INTENTIONALLY_NOT_SENSITIVE -keystore /tmp/AmazonRootCA1.jks >/dev/null 2>&1
cp /tmp/AmazonRootCA1.jks /opt/tak/certs/files/aws-acm-root.jks

# Generate CoreConfig.xml
cat > "$OUTPUT_FILE" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Configuration xmlns="http://bbn.com/marti/xml/config">
    <network multicastTTL="5" serverId="${SERVER_ID}" version="${TAK_VERSION}" cloudwatchEnable="true" cloudwatchName="${StackName}"$(add_attr "allowAllOrigins" "$(get_env_value "TAKSERVER_CoreConfig_Network_AllowAllOrigins" "false" "boolean")" "false")$(add_attr "enableHSTS" "$(get_env_value "TAKSERVER_CoreConfig_Network_EnableHSTS" "true" "boolean")" "true")>
        <input auth="$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Auth" "x509")" _name="stdssl" protocol="tls" port="8089" coreVersion="2"$(add_attr "archive" "$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Archive" "true" "boolean")" "true")/>
        <connector port="8443" _name="https" keystore="JKS" keystoreFile="/opt/tak/certs/files/${LETSENCRYPT_DOMAIN}/letsencrypt.jks" keystorePass="atakatak"$(add_attr "enableAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI" "true" "boolean")" "true")$(add_attr "enableWebtak" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak" "true" "boolean")" "true")$(add_attr "enableNonAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableNonAdminUI" "true" "boolean")" "true")$(add_attr "allowOrigins" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_AllowOrigins" "")" "")/>
        <connector port="8446" _name="cert_https" keystore="JKS" keystoreFile="/opt/tak/certs/files/${LETSENCRYPT_DOMAIN}/letsencrypt.jks" keystorePass="atakatak" clientAuth="false"$(add_attr "enableAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableAdminUI" "true" "boolean")" "true")$(add_attr "enableWebtak" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak" "true" "boolean")" "true")$(add_attr "enableNonAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableNonAdminUI" "true" "boolean")" "true")$(add_attr "allowOrigins" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_AllowOrigins" "")" "")/>
        <announce$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Network_Announce_Enable" "false" "boolean")" "false")/>
    </network>
    <auth default="$(get_env_value "TAKSERVER_CoreConfig_Auth_Default" "ldap")"$(add_attr "x509groups" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509groups" "true" "boolean")" "true")$(add_attr "x509addAnonymous" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509addAnonymous" "false" "boolean")" "false")$(add_attr "x509useGroupCache" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCache" "false" "boolean")" "false")$(add_attr "x509useGroupCacheDefaultActive" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive" "false" "boolean")" "false")$(add_attr "x509checkRevocation" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509checkRevocation" "false" "boolean")" "false")>
        <ldap url="${LDAP_SECURE_URL}" userstring="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Userstring" "")${LDAP_DN}" serviceAccountDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_ServiceAccountDN" "")${LDAP_DN}" serviceAccountCredential="${LDAP_Password}" groupBaseRDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupBaseRDN" "")${LDAP_DN}" userBaseRDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_UserBaseRDN" "")${LDAP_DN}" callsignAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_CallsignAttribute" "")" colorAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_ColorAttribute" "")" roleAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_RoleAttribute" "")"$(add_attr "updateinterval" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Updateinterval" "60")" "")$(add_attr "groupprefix" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix" "")" "")$(add_attr "groupNameExtractorRegex" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex" "CN=(.*?)(?:,|$)")" "CN=(.*?)(?:,|$)")$(add_attr "style" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Style" "DS")" "DS")$(add_attr "userObjectClass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_UserObjectClass" "user")" "user")$(add_attr "groupObjectClass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass" "group")" "group")$(add_attr "dnAttributeName" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_DnAttributeName" "distinguishedName")" "distinguishedName")$(add_attr "nameAttr" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_NameAttr" "cn")" "cn")$(add_attr "nestedGroupLookup" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_NestedGroupLookup" "false" "boolean")" "false")/>
EOF

# Add OAuth section if OAuth server is configured
oauth_server_name=$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Name" "")
if [[ -n "$oauth_server_name" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
        <oauth$(add_attr "oauthUseGroupCache" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_OauthUseGroupCache" "false" "boolean")" "false")$(add_attr "loginWithEmail" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_LoginWithEmail" "false" "boolean")" "false")$(add_attr "useTakServerLoginPage" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_UseTakServerLoginPage" "false" "boolean")" "false")$(add_attr "allowUriQueryParameter" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_AllowUriQueryParameter" "false" "boolean")" "false")$(add_attr "groupsClaim" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_GroupsClaim" "groups")" "groups")$(add_attr "groupprefix" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_Groupprefix" "")" "")>
EOF
    
    # Add optional OAuth child elements
    groups_claim=$(get_env_value "TAKSERVER_CoreConfig_OAuth_GroupsClaim" "")
    username_claim=$(get_env_value "TAKSERVER_CoreConfig_OAuth_UsernameClaim" "")
    scope_claim=$(get_env_value "TAKSERVER_CoreConfig_OAuth_ScopeClaim" "")
    webtak_scope=$(get_env_value "TAKSERVER_CoreConfig_OAuth_WebtakScope" "")
    group_prefix=$(get_env_value "TAKSERVER_CoreConfig_OAuth_Groupprefix" "")
    
    [[ -n "$groups_claim" && "$groups_claim" != "groups" ]] && echo "            <groupsClaim>$groups_claim</groupsClaim>" >> "$OUTPUT_FILE"
    [[ -n "$username_claim" ]] && echo "            <usernameClaim>$username_claim</usernameClaim>" >> "$OUTPUT_FILE"
    [[ -n "$scope_claim" && "$scope_claim" != "scope" ]] && echo "            <scopeClaim>$scope_claim</scopeClaim>" >> "$OUTPUT_FILE"
    [[ -n "$webtak_scope" ]] && echo "            <webtakScope>$webtak_scope</webtakScope>" >> "$OUTPUT_FILE"
    [[ -n "$group_prefix" ]] && echo "            <groupprefix>$group_prefix</groupprefix>" >> "$OUTPUT_FILE"
    
    cat >> "$OUTPUT_FILE" << EOF
            <authServer name="$oauth_server_name" issuer="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Issuer" "")" clientId="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_ClientId" "")" secret="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Secret" "")" redirectUri="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RedirectUri" "")" scope="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Scope" "")" authEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint" "")" tokenEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint" "")"$(add_attr "accessTokenName" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AccessTokenName" "access_token")" "access_token")$(add_attr "refreshTokenName" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RefreshTokenName" "refresh_token")" "refresh_token")$(add_attr "trustAllCerts" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts" "false" "boolean")" "false")/>
        </oauth>
EOF
fi

# Close auth section and add other required elements
cat >> "$OUTPUT_FILE" << EOF
    </auth>
    <submission$(add_attr "validateXml" "$(get_env_value "TAKSERVER_CoreConfig_Submission_ValidateXml" "false" "boolean")" "false")/>
    <subscription$(add_attr "reloadPersistent" "$(get_env_value "TAKSERVER_CoreConfig_Subscription_ReloadPersistent" "false" "boolean")" "false")/>
    <repository$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Repository_Enable" "true" "boolean")" "true")$(add_attr "archive" "$(get_env_value "TAKSERVER_CoreConfig_Repository_Archive" "false" "boolean")" "false")>
        <connection url="${PostgresURL}" username="${PostgresUsername}" password="${PostgresPassword}"$(add_attr "sslEnabled" "$(get_env_value "TAKSERVER_CoreConfig_Repository_Connection_SslEnabled" "false" "boolean")" "false")/>
    </repository>
    <repeater$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Repeater_Enable" "false" "boolean")" "false")/>
    <filter/>
    <buffer>
        <queue$(add_attr "disconnectOnFull" "$(get_env_value "TAKSERVER_CoreConfig_Buffer_Queue_DisconnectOnFull" "false" "boolean")" "false")/>
        <latestSA$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Buffer_LatestSA_Enable" "false" "boolean")" "false")/>
    </buffer>
    <dissemination$(add_attr "enabled" "$(get_env_value "TAKSERVER_CoreConfig_Dissemination_Enabled" "true" "boolean")" "true")/>
    <security>
        <tls keystore="JKS" keystoreFile="/opt/tak/certs/files/takserver.jks" keystorePass="atakatak" truststore="JKS" truststoreFile="/opt/tak/certs/files/truststore-root.jks" truststorePass="atakatak" keymanager="SunX509"$(add_attr "context" "$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_Context" "TLSv1.2")" "TLSv1.2")/>
    </security>
EOF

# Add Federation section if enabled
federation_enabled=$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableFederation" "false" "boolean")
if [[ "$federation_enabled" == "true" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
    <federation enableFederation="true"$(add_attr "allowFederatedDelete" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowFederatedDelete" "false" "boolean")" "false")$(add_attr "allowMissionFederation" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowMissionFederation" "true" "boolean")" "true")$(add_attr "allowDataFeedFederation" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowDataFeedFederation" "true" "boolean")" "true")$(add_attr "enableMissionFederationDisruptionTolerance" "$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableMissionFederationDisruptionTolerance" "true" "boolean")" "true")$(add_attr "missionFederationDisruptionToleranceRecencySeconds" "$(get_env_value "TAKSERVER_CoreConfig_Federation_MissionFederationDisruptionToleranceRecencySeconds" "43200")" "43200")$(add_attr "enableDataPackageAndMissionFileFilter" "$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableDataPackageAndMissionFileFilter" "false" "boolean")" "false")>
        <federation-server webBaseUrl="$(get_env_value "TAKSERVER_CoreConfig_Federation_WebBaseUrl" "")">
            <tls keystore="JKS" keystoreFile="/opt/tak/certs/files/takserver.jks" keystorePass="atakatak" truststore="JKS" truststoreFile="/opt/tak/certs/files/truststore-root.jks" truststorePass="atakatak" keymanager="SunX509"/>
        </federation-server>
        <fileFilter/>
    </federation>
EOF
fi

# Close the Configuration tag
echo "</Configuration>" >> "$OUTPUT_FILE"

echo "ok - TAK Server - CoreConfig.xml generated successfully at $OUTPUT_FILE"