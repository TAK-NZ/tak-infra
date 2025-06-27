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

# Add attribute always (for non-default values)
add_attr_always() {
    local attr_name="$1"
    local value="$2"
    [[ -n "$value" ]] && echo -n " $attr_name=\"$value\""
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
    <network multicastTTL="5" serverId="${SERVER_ID}" version="${TAK_VERSION}" cloudwatchEnable="$(get_env_value "TAKSERVER_CoreConfig_Network_CloudwatchEnable" "false" "boolean")" cloudwatchName="${StackName}"$(add_attr "allowAllOrigins" "$(get_env_value "TAKSERVER_CoreConfig_Network_AllowAllOrigins" "false" "boolean")" "false")$(add_attr "enableHSTS" "$(get_env_value "TAKSERVER_CoreConfig_Network_EnableHSTS" "true" "boolean")" "true")>
        <input auth="$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Auth" "x509")" _name="stdssl" protocol="tls" port="8089" coreVersion="2"$(add_attr "archive" "$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Archive" "true" "boolean")" "true")/>
        <connector port="8443" _name="https" keystore="JKS" keystoreFile="/opt/tak/certs/files/${LETSENCRYPT_DOMAIN}/letsencrypt.jks" keystorePass="atakatak"$(add_attr "enableAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI" "true" "boolean")" "false")$(add_attr "enableWebtak" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak" "true" "boolean")" "false")$(add_attr "enableNonAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableNonAdminUI" "true" "boolean")" "false")/>
        <connector port="8446" clientAuth="false" _name="cert_https" keystore="JKS" keystoreFile="/opt/tak/certs/files/${LETSENCRYPT_DOMAIN}/letsencrypt.jks" keystorePass="atakatak"$(add_attr "enableAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableAdminUI" "true" "boolean")" "false")$(add_attr "enableWebtak" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak" "true" "boolean")" "false")$(add_attr "enableNonAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableNonAdminUI" "true" "boolean")" "false")/>
        <announce$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Network_Announce_Enable" "false" "boolean")" "false")/>
    </network>
    <auth default="$(get_env_value "TAKSERVER_CoreConfig_Auth_Default" "ldap")"$(add_attr "x509groups" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509groups" "true" "boolean")" "false")$(add_attr "x509addAnonymous" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509addAnonymous" "false" "boolean")" "true")$(add_attr "x509useGroupCache" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCache" "true" "boolean")" "false")$(add_attr "x509useGroupCacheDefaultActive" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive" "true" "boolean")" "false")$(add_attr "x509checkRevocation" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509checkRevocation" "true" "boolean")" "false")>
        <ldap url="${LDAP_SECURE_URL}" userstring="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Userstring" "cn={username},ou=users,")${LDAP_DN}" updateinterval="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Updateinterval" "60")"$(add_attr_always "groupprefix" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix" "")")$(add_attr "groupNameExtractorRegex" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex" "CN=(.*?)(?:,|$)")" "CN=(.*?)(?:,|$)")$(add_attr "style" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Style" "DS")" "DS") serviceAccountDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_ServiceAccountDN" "cn=ldapservice,ou=users,")${LDAP_DN}" serviceAccountCredential="${LDAP_Password}"$(add_attr "groupObjectClass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass" "group")" "group")$(add_attr "userObjectClass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_UserObjectClass" "user")" "user") groupBaseRDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupBaseRDN" "ou=groups,")${LDAP_DN}" userBaseRDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_UserBaseRDN" "ou=users,")${LDAP_DN}"$(add_attr "nestedGroupLookup" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_NestedGroupLookup" "false" "boolean")" "false")$(add_attr_always "ldapsTruststore" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststore" "JKS")")$(add_attr_always "ldapsTruststoreFile" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststoreFile" "/opt/tak/certs/files/aws-acm-root.jks")")$(add_attr_always "ldapsTruststorePass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststorePass" "INTENTIONALLY_NOT_SENSITIVE")") callsignAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_CallsignAttribute" "takCallsign")" colorAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_ColorAttribute" "takColor")" roleAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_RoleAttribute" "takRole")"$(add_attr "enableConnectionPool" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_EnableConnectionPool" "false" "boolean")" "false")$(add_attr "dnAttributeName" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_DnAttributeName" "DN")" "distinguishedName")$(add_attr "nameAttr" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_NameAttr" "CN")" "cn")/>
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
    
    # Add OAuth server configuration
    cat >> "$OUTPUT_FILE" << EOF
            <authServer name="$oauth_server_name" issuer="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Issuer" "")" clientId="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_ClientId" "")" secret="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Secret" "")" redirectUri="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RedirectUri" "")" scope="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Scope" "")" authEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint" "")" tokenEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint" "")"$(add_attr "accessTokenName" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AccessTokenName" "access_token")" "access_token")$(add_attr "refreshTokenName" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RefreshTokenName" "refresh_token")" "refresh_token")$(add_attr "trustAllCerts" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts" "false" "boolean")" "false")/>
EOF
    echo "        </oauth>" >> "$OUTPUT_FILE"
fi

# Complete the auth section and add remaining sections
cat >> "$OUTPUT_FILE" << EOF
    </auth>
    <submission$(add_attr "ignoreStaleMessages" "$(get_env_value "TAKSERVER_CoreConfig_Submission_IgnoreStaleMessages" "false" "boolean")" "false")$(add_attr "validateXml" "$(get_env_value "TAKSERVER_CoreConfig_Submission_ValidateXml" "false" "boolean")" "false")/>
    <subscription$(add_attr "reloadPersistent" "$(get_env_value "TAKSERVER_CoreConfig_Subscription_ReloadPersistent" "false" "boolean")" "false")/>
    <repository$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Repository_Enable" "true" "boolean")" "false")$(add_attr "numDbConnections" "$(get_env_value "TAKSERVER_CoreConfig_Repository_NumDbConnections" "16")" "")$(add_attr "primaryKeyBatchSize" "$(get_env_value "TAKSERVER_CoreConfig_Repository_PrimaryKeyBatchSize" "500")" "")$(add_attr "insertionBatchSize" "$(get_env_value "TAKSERVER_CoreConfig_Repository_InsertionBatchSize" "500")" "")>
        <connection url="${PostgresURL}" username="${PostgresUsername}" password="${PostgresPassword}"/>
    </repository>
    <repeater$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Repeater_Enable" "true" "boolean")" "false")$(add_attr "periodMillis" "$(get_env_value "TAKSERVER_CoreConfig_Repeater_PeriodMillis" "3000")" "")$(add_attr "staleDelayMillis" "$(get_env_value "TAKSERVER_CoreConfig_Repeater_StaleDelayMillis" "15000")" "")>
EOF

# Add repeatable types if repeater is enabled
if [[ "$(get_env_value "TAKSERVER_CoreConfig_Repeater_Enable" "true" "boolean")" == "true" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
        <repeatableType initiate-test="/event/detail/emergency[@type='911 Alert']" cancel-test="/event/detail/emergency[@cancel='true']" _name="911"/>
        <repeatableType initiate-test="/event/detail/emergency[@type='Ring The Bell']" cancel-test="/event/detail/emergency[@cancel='true']" _name="RingTheBell"/>
        <repeatableType initiate-test="/event/detail/emergency[@type='Geo-fence Breached']" cancel-test="/event/detail/emergency[@cancel='true']" _name="GeoFenceBreach"/>
        <repeatableType initiate-test="/event/detail/emergency[@type='Troops In Contact']" cancel-test="/event/detail/emergency[@cancel='true']" _name="TroopsInContact"/>
EOF
fi

cat >> "$OUTPUT_FILE" << EOF
    </repeater>
    <filter>
        <thumbnail/>
        <urladd host="$(get_env_value "TAKSERVER_CoreConfig_Filter_Urladd_Host" "http://10.0.2.95:8080")"/>
        <flowtag/>
        <streamingbroker/>
        <qos>
            <deliveryRateLimiter enabled="$(get_env_value "TAKSERVER_CoreConfig_Filter_QOS_DeliveryRateLimiter_Enabled" "true" "boolean")">
                <rateLimitRule clientThresholdCount="500" reportingRateLimitSeconds="200"/>
                <rateLimitRule clientThresholdCount="1000" reportingRateLimitSeconds="300"/>
                <rateLimitRule clientThresholdCount="2000" reportingRateLimitSeconds="400"/>
                <rateLimitRule clientThresholdCount="5000" reportingRateLimitSeconds="800"/>
                <rateLimitRule clientThresholdCount="10000" reportingRateLimitSeconds="1200"/>
            </deliveryRateLimiter>
            <readRateLimiter enabled="$(get_env_value "TAKSERVER_CoreConfig_Filter_QOS_ReadRateLimiter_Enabled" "false" "boolean")">
                <rateLimitRule clientThresholdCount="500" reportingRateLimitSeconds="200"/>
                <rateLimitRule clientThresholdCount="1000" reportingRateLimitSeconds="300"/>
                <rateLimitRule clientThresholdCount="2000" reportingRateLimitSeconds="400"/>
                <rateLimitRule clientThresholdCount="5000" reportingRateLimitSeconds="800"/>
                <rateLimitRule clientThresholdCount="10000" reportingRateLimitSeconds="1200"/>
            </readRateLimiter>
            <dosRateLimiter enabled="$(get_env_value "TAKSERVER_CoreConfig_Filter_QOS_DosRateLimiter_Enabled" "false" "boolean")" intervalSeconds="$(get_env_value "TAKSERVER_CoreConfig_Filter_QOS_DosRateLimiter_IntervalSeconds" "60")">
                <dosLimitRule clientThresholdCount="1" messageLimitPerInterval="60"/>
            </dosRateLimiter>
        </qos>
    </filter>
    <buffer>
        <queue>
            <priority/>
        </queue>
        <latestSA$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Buffer_LatestSA_Enable" "true" "boolean")" "false")/>
    </buffer>
    <dissemination$(add_attr "smartRetry" "$(get_env_value "TAKSERVER_CoreConfig_Dissemination_SmartRetry" "false" "boolean")" "false")/>
    <certificateSigning CA="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_CA" "TAKServer")">
        <certificateConfig>
            <nameEntries>
                <nameEntry name="O" value="$(get_env_value "TAKSERVER_CACert_Org" "TAK")"/>
                <nameEntry name="OU" value="$(get_env_value "TAKSERVER_CACert_OrgUnit" "TAK Unit")"/>
            </nameEntries>
        </certificateConfig>
        <TAKServerCAConfig keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_KeystoreFile" "/opt/tak/certs/files/intermediate-ca-signing.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_KeystorePass" "atakatak")" validityDays="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_ValidityDays" "365")" signatureAlg="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_SignatureAlg" "SHA256WithRSA")" CAkey="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_CAkey" "/opt/tak/certs/files/intermediate-ca-signing")" CAcertificate="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_CAcertificate" "/opt/tak/certs/files/intermediate-ca-signing")"/>
    </certificateSigning>
EOF

# Add certificate signing section if explicitly enabled (legacy support)
if [[ "$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_Enable" "false" "boolean")" == "true" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
    <certificateSigning CA="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_CA" "TAKServer")">
        <certificateConfig>
            <nameEntries>
                <nameEntry name="O" value="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_O" "TAK.NZ")"/>
                <nameEntry name="OU" value="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_OU" "TAK.NZ Operations")"/>
            </nameEntries>
        </certificateConfig>
        <TAKServerCAConfig keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_KeystoreFile" "/opt/tak/certs/files/intermediate-ca-signing.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_KeystorePass" "atakatak")" validityDays="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_ValidityDays" "365")" signatureAlg="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_SignatureAlg" "SHA256WithRSA")" CAkey="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_CAkey" "/opt/tak/certs/files/intermediate-ca-signing")" CAcertificate="$(get_env_value "TAKSERVER_CoreConfig_CertificateSigning_CAcertificate" "/opt/tak/certs/files/intermediate-ca-signing")"/>
    </certificateSigning>
EOF
fi

cat >> "$OUTPUT_FILE" << EOF
    <security>
        <tls keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_KeystoreFile" "/opt/tak/certs/files/takserver.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_KeystorePass" "atakatak")" truststore="JKS" truststoreFile="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_TruststoreFile" "/opt/tak/certs/files/truststore-root.jks")" truststorePass="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_TruststorePass" "atakatak")" keymanager="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_Keymanager" "SunX509")"$(add_attr "context" "$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_Context" "TLSv1.2")" "")/>
EOF

# Add mission TLS if configured
if [[ -n "$(get_env_value "TAKSERVER_CoreConfig_Security_MissionTLS_KeystoreFile" "")" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
        <missionTls keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_Security_MissionTLS_KeystoreFile" "/opt/tak/certs/files/truststore-root.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_Security_MissionTLS_KeystorePass" "atakatak")"/>
EOF
fi

cat >> "$OUTPUT_FILE" << EOF
    </security>
    <federation$(add_attr "allowFederatedDelete" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowFederatedDelete" "false" "boolean")" "false")$(add_attr "allowMissionFederation" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowMissionFederation" "true" "boolean")" "false")$(add_attr "allowDataFeedFederation" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowDataFeedFederation" "true" "boolean")" "false")$(add_attr "enableMissionFederationDisruptionTolerance" "$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableMissionFederationDisruptionTolerance" "true" "boolean")" "false") missionFederationDisruptionToleranceRecencySeconds="$(get_env_value "TAKSERVER_CoreConfig_Federation_MissionFederationDisruptionToleranceRecencySeconds" "43200")" enableFederation="$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableFederation" "true" "boolean")"$(add_attr "enableDataPackageAndMissionFileFilter" "$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableDataPackageAndMissionFileFilter" "false" "boolean")" "false")>
        <federation-server$(add_attr "port" "$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_Port" "9000")" "")$(add_attr "coreVersion" "$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_CoreVersion" "2")" "")$(add_attr "v1enabled" "$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_V1enabled" "false" "boolean")" "false")$(add_attr "v2port" "$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_V2port" "9001")" "")$(add_attr "v2enabled" "$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_V2enabled" "true" "boolean")" "false") webBaseUrl="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_WebBaseUrl" "https://localhost:8443/Marti")">
            <tls keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_KeystoreFile" "/opt/tak/certs/files/takserver.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_KeystorePass" "atakatak")" truststore="JKS" truststoreFile="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_TruststoreFile" "/opt/tak/certs/files/truststore-root.jks")" truststorePass="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_TruststorePass" "atakatak")" keymanager="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_Keymanager" "SunX509")"$(add_attr "context" "$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_Context" "TLSv1.2")" "")/>
EOF

# Add federation port if configured
if [[ -n "$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_Port" "9000")" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
            <federation-port port="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_Port" "9000")" tlsVersion="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLSVersion" "TLSv1.2")"/>
EOF
fi

cat >> "$OUTPUT_FILE" << EOF
            <v1Tls tlsVersion="TLSv1.2"/>
            <v1Tls tlsVersion="TLSv1.3"/>
        </federation-server>
        <fileFilter>
EOF

# Add file extensions if configured
file_extensions=$(get_env_value "TAKSERVER_CoreConfig_Federation_FileFilter_Extensions" "pref")
if [[ -n "$file_extensions" ]]; then
    IFS=',' read -ra EXTENSIONS <<< "$file_extensions"
    for ext in "${EXTENSIONS[@]}"; do
        echo "            <fileExtension>$ext</fileExtension>" >> "$OUTPUT_FILE"
    done
fi

cat >> "$OUTPUT_FILE" << EOF
        </fileFilter>
    </federation>
    <plugins/>
    <cluster/>
    <vbm/>
</Configuration>
EOF

echo "TAK Server - CoreConfig.xml generated successfully at $OUTPUT_FILE"