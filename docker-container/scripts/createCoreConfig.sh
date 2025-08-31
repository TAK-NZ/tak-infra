#!/bin/bash

# Get output file path (default to /opt/tak/CoreConfig.xml if not provided)
OUTPUT_FILE="${1:-/opt/tak/CoreConfig.xml}"
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_FILE=$(mktemp)
EXISTING_FILE=""

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

# Track which settings are driven by environment variables
declare -A ENV_DRIVEN_SETTINGS=()

# Define explicit XPath mappings for complex paths
# Format: "ENV_VAR_NAME" -> "/Configuration/path/to/element[@attr='value']/@targetAttr"
declare -A XPATH_MAPPINGS=(
    # Network settings
    ["TAKSERVER_CoreConfig_Network_CloudwatchEnable"]="/Configuration/network/@cloudwatchEnable"
    ["TAKSERVER_CoreConfig_Network_AllowAllOrigins"]="/Configuration/network/@allowAllOrigins"
    ["TAKSERVER_CoreConfig_Network_EnableHSTS"]="/Configuration/network/@enableHSTS"
    ["TAKSERVER_CoreConfig_Network_Input_8089_Auth"]="/Configuration/network/input[@_name='stdssl']/@auth"
    ["TAKSERVER_CoreConfig_Network_Input_8089_Archive"]="/Configuration/network/input[@_name='stdssl']/@archive"
    ["TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI"]="/Configuration/network/connector[@port='8443']/@enableAdminUI"
    ["TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak"]="/Configuration/network/connector[@port='8443']/@enableWebtak"
    ["TAKSERVER_CoreConfig_Network_Connector_8443_EnableNonAdminUI"]="/Configuration/network/connector[@port='8443']/@enableNonAdminUI"
    ["TAKSERVER_CoreConfig_Network_Connector_8446_EnableAdminUI"]="/Configuration/network/connector[@port='8446']/@enableAdminUI"
    ["TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak"]="/Configuration/network/connector[@port='8446']/@enableWebtak"
    ["TAKSERVER_CoreConfig_Network_Connector_8446_EnableNonAdminUI"]="/Configuration/network/connector[@port='8446']/@enableNonAdminUI"
    ["TAKSERVER_CoreConfig_Network_Announce_Enable"]="/Configuration/network/announce/@enable"
    
    # Auth settings
    ["TAKSERVER_CoreConfig_Auth_Default"]="/Configuration/auth/@default"
    ["TAKSERVER_CoreConfig_Auth_X509groups"]="/Configuration/auth/@x509groups"
    ["TAKSERVER_CoreConfig_Auth_X509addAnonymous"]="/Configuration/auth/@x509addAnonymous"
    ["TAKSERVER_CoreConfig_Auth_X509useGroupCache"]="/Configuration/auth/@x509useGroupCache"
    ["TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive"]="/Configuration/auth/@x509useGroupCacheDefaultActive"
    ["TAKSERVER_CoreConfig_Auth_X509checkRevocation"]="/Configuration/auth/@x509checkRevocation"
    
    # LDAP settings
    ["TAKSERVER_CoreConfig_Auth_LDAP_Userstring"]="/Configuration/auth/ldap/@userstring"
    ["TAKSERVER_CoreConfig_Auth_LDAP_Updateinterval"]="/Configuration/auth/ldap/@updateinterval"
    ["TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix"]="/Configuration/auth/ldap/@groupprefix"
    ["TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex"]="/Configuration/auth/ldap/@groupNameExtractorRegex"
    ["TAKSERVER_CoreConfig_Auth_LDAP_Style"]="/Configuration/auth/ldap/@style"
    ["TAKSERVER_CoreConfig_Auth_LDAP_ServiceAccountDN"]="/Configuration/auth/ldap/@serviceAccountDN"
    ["TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass"]="/Configuration/auth/ldap/@groupObjectClass"
    ["TAKSERVER_CoreConfig_Auth_LDAP_UserObjectClass"]="/Configuration/auth/ldap/@userObjectClass"
    ["TAKSERVER_CoreConfig_Auth_LDAP_GroupBaseRDN"]="/Configuration/auth/ldap/@groupBaseRDN"
    ["TAKSERVER_CoreConfig_Auth_LDAP_UserBaseRDN"]="/Configuration/auth/ldap/@userBaseRDN"
    ["TAKSERVER_CoreConfig_Auth_LDAP_NestedGroupLookup"]="/Configuration/auth/ldap/@nestedGroupLookup"
    ["TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststore"]="/Configuration/auth/ldap/@ldapsTruststore"
    ["TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststoreFile"]="/Configuration/auth/ldap/@ldapsTruststoreFile"
    ["TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststorePass"]="/Configuration/auth/ldap/@ldapsTruststorePass"
    ["TAKSERVER_CoreConfig_Auth_LDAP_CallsignAttribute"]="/Configuration/auth/ldap/@callsignAttribute"
    ["TAKSERVER_CoreConfig_Auth_LDAP_ColorAttribute"]="/Configuration/auth/ldap/@colorAttribute"
    ["TAKSERVER_CoreConfig_Auth_LDAP_RoleAttribute"]="/Configuration/auth/ldap/@roleAttribute"
    ["TAKSERVER_CoreConfig_Auth_LDAP_EnableConnectionPool"]="/Configuration/auth/ldap/@enableConnectionPool"
    ["TAKSERVER_CoreConfig_Auth_LDAP_DnAttributeName"]="/Configuration/auth/ldap/@dnAttributeName"
    ["TAKSERVER_CoreConfig_Auth_LDAP_NameAttr"]="/Configuration/auth/ldap/@nameAttr"
    
    # Federation settings
    ["TAKSERVER_CoreConfig_Federation_EnableFederation"]="/Configuration/federation/@enableFederation"
    ["TAKSERVER_CoreConfig_Federation_WebBaseUrl"]="/Configuration/federation/federation-server/@webBaseUrl"
    ["TAKSERVER_CoreConfig_Federation_Server_TLS_Context"]="/Configuration/federation/federation-server/tls/@context"
    
    # Submission/Subscription settings
    ["TAKSERVER_CoreConfig_Submission_IgnoreStaleMessages"]="/Configuration/submission/@ignoreStaleMessages"
    ["TAKSERVER_CoreConfig_Submission_ValidateXml"]="/Configuration/submission/@validateXml"
    ["TAKSERVER_CoreConfig_Subscription_ReloadPersistent"]="/Configuration/subscription/@reloadPersistent"
    
    # Security settings
    ["TAKSERVER_CoreConfig_Security_TLS_Context"]="/Configuration/security/tls/@context"
    
    # OAuth settings
    ["TAKSERVER_CoreConfig_Auth_Oauth_OauthAddAnonymous"]="/Configuration/auth/oauth/@oauthAddAnonymous"
    ["TAKSERVER_CoreConfig_Auth_Oauth_OauthUseGroupCache"]="/Configuration/auth/oauth/@oauthUseGroupCache"
    ["TAKSERVER_CoreConfig_Auth_Oauth_GroupsClaim"]="/Configuration/auth/oauth/@groupsClaim"
    ["TAKSERVER_CoreConfig_Auth_Oauth_UsernameClaim"]="/Configuration/auth/oauth/@usernameClaim"
    ["TAKSERVER_CoreConfig_OAuth_OauthAddAnonymous"]="/Configuration/auth/oauth/@oauthAddAnonymous"
    ["TAKSERVER_CoreConfig_OAuth_OauthUseGroupCache"]="/Configuration/auth/oauth/@oauthUseGroupCache"
    ["TAKSERVER_CoreConfig_OAuth_LoginWithEmail"]="/Configuration/auth/oauth/@loginWithEmail"
    ["TAKSERVER_CoreConfig_OAuth_UseTakServerLoginPage"]="/Configuration/auth/oauth/@useTakServerLoginPage"
    ["TAKSERVER_CoreConfig_OAuth_ReadOnlyGroup"]="/Configuration/auth/oauth/@readOnlyGroup"
    ["TAKSERVER_CoreConfig_OAuth_ReadGroupSuffix"]="/Configuration/auth/oauth/@readGroupSuffix"
    ["TAKSERVER_CoreConfig_OAuth_WriteGroupSuffix"]="/Configuration/auth/oauth/@writeGroupSuffix"
    ["TAKSERVER_CoreConfig_OAuth_GroupsClaim"]="/Configuration/auth/oauth/@groupsClaim"
    ["TAKSERVER_CoreConfig_OAuth_UsernameClaim"]="/Configuration/auth/oauth/@usernameClaim"
    ["TAKSERVER_CoreConfig_OAuth_Groupprefix"]="/Configuration/auth/oauth/@groupprefix"
    
    # OAuth Server settings
    ["TAKSERVER_CoreConfig_OAuthServer_Name"]="/Configuration/auth/oauth/authServer/@name"
    ["TAKSERVER_CoreConfig_OAuthServer_Issuer"]="/Configuration/auth/oauth/authServer/@issuer"
    ["TAKSERVER_CoreConfig_OAuthServer_ClientId"]="/Configuration/auth/oauth/authServer/@clientId"
    ["TAKSERVER_CoreConfig_OAuthServer_Secret"]="/Configuration/auth/oauth/authServer/@secret"
    ["TAKSERVER_CoreConfig_OAuthServer_RedirectUri"]="/Configuration/auth/oauth/authServer/@redirectUri"
    ["TAKSERVER_CoreConfig_OAuthServer_Scope"]="/Configuration/auth/oauth/authServer/@scope"
    ["TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint"]="/Configuration/auth/oauth/authServer/@authEndpoint"
    ["TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint"]="/Configuration/auth/oauth/authServer/@tokenEndpoint"
    ["TAKSERVER_CoreConfig_OAuthServer_AccessTokenName"]="/Configuration/auth/oauth/authServer/@accessTokenName"
    ["TAKSERVER_CoreConfig_OAuthServer_RefreshTokenName"]="/Configuration/auth/oauth/authServer/@refreshTokenName"
    ["TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts"]="/Configuration/auth/oauth/authServer/@trustAllCerts"
    
    # Profile settings
    ["TAKSERVER_CoreConfig_Profile_UseStreamingGroup"]="/Configuration/profile/@useStreamingGroup"
    
    # Locate settings
    ["TAKSERVER_CoreConfig_Locate_Enabled"]="/Configuration/locate/@enabled"
    ["TAKSERVER_CoreConfig_Locate_RequireLogin"]="/Configuration/locate/@requireLogin"
    ["TAKSERVER_CoreConfig_Locate_CotType"]="/Configuration/locate/@cot-type"
    ["TAKSERVER_CoreConfig_Locate_Group"]="/Configuration/locate/@group"
    ["TAKSERVER_CoreConfig_Locate_Broadcast"]="/Configuration/locate/@broadcast"
    ["TAKSERVER_CoreConfig_Locate_AddToMission"]="/Configuration/locate/@addToMission"
    ["TAKSERVER_CoreConfig_Locate_Mission"]="/Configuration/locate/@mission"
)

# Helper function to get XPath for an environment variable
get_xpath_for_env() {
    local env_var="$1"
    
    # Check if we have an explicit mapping
    if [[ -n "${XPATH_MAPPINGS[$env_var]}" ]]; then
        echo "${XPATH_MAPPINGS[$env_var]}"
        return
    fi
    
    # Default fallback for simple paths
    # This is a best-effort approach and may not work for complex paths
    local path="${env_var#TAKSERVER_CoreConfig_}"
    
    # Convert underscores in path components to slashes for XML hierarchy
    local xml_path="${path//\_/\/}"
    
    # Find the last component which might contain an attribute
    local last_component="${xml_path##*/}"
    local prefix_path="${xml_path%/*}"
    
    # If there's no slash, the entire path is the last component
    if [[ "$xml_path" == "$last_component" ]]; then
        prefix_path=""
    else
        prefix_path="$prefix_path/"
    fi
    
    # Check if the last component has an underscore which might indicate an attribute
    if [[ "$last_component" == *_* ]]; then
        # Extract attribute name (after last underscore)
        local attr_name="${last_component##*_}"
        # Extract element name (before last underscore)
        local elem_name="${last_component%_*}"
        echo "/Configuration/$prefix_path$elem_name/@$attr_name"
    else
        echo "/Configuration/$xml_path"
    fi
    
    # Log warning for unmapped variables to help with debugging
    echo "Warning: No explicit XPath mapping for $env_var, using best-effort conversion" >&2
}

# Helper function to record environment-driven settings
record_env_setting() {
    local xpath="$1"
    local env_var="$2"
    
    # Only record if the environment variable is set
    if [[ -n "${!env_var}" ]]; then
        ENV_DRIVEN_SETTINGS["$xpath"]="$env_var"
    fi
}

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
    
    # Record this setting as environment-driven if the env var is set
    if [[ -n "${!env_path}" ]]; then
        local xpath=$(get_xpath_for_env "$env_path")
        record_env_setting "$xpath" "$env_path"
    fi
    
    # Validate value based on type
    if [[ "$type" == "boolean" ]]; then
        # Convert to proper boolean
        env_value=$(string_to_boolean "$env_value")
    elif [[ "$type" == "integer" ]]; then
        # Validate integer
        if ! [[ "$env_value" =~ ^[0-9]+$ ]]; then
            echo "Warning: Value '$env_value' for $env_path is not a valid integer, using default '$xsd_default'" >&2
            env_value="$xsd_default"
        fi
    elif [[ "$type" == "url" ]]; then
        # Basic URL validation
        if ! [[ "$env_value" =~ ^https?:// ]]; then
            echo "Warning: Value '$env_value' for $env_path does not appear to be a valid URL" >&2
        fi
    fi
    
    echo "$env_value"
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

# Check if the file exists and is a valid XML file
check_existing_file() {
    if [[ -f "$OUTPUT_FILE" ]]; then
        if xmlstarlet val -q "$OUTPUT_FILE"; then
            EXISTING_FILE="$OUTPUT_FILE"
            echo "Found existing valid CoreConfig.xml, will merge with environment settings"
            # Create a backup of the existing file
            cp "$OUTPUT_FILE" "${OUTPUT_FILE}.bak"
            
            # Validate against schema if available
            if [[ -f "/opt/tak/CoreConfig.xsd" ]]; then
                echo "Validating existing CoreConfig.xml against schema..."
                if ! xmlstarlet val -q -s "/opt/tak/CoreConfig.xsd" "$OUTPUT_FILE" 2>/dev/null; then
                    echo "Warning: Existing CoreConfig.xml does not validate against schema"
                    echo "Will attempt to fix validation issues during merge process"
                fi
            fi
        else
            echo "Warning: Existing CoreConfig.xml is not valid XML, creating new file"
        fi
    else
        echo "No existing CoreConfig.xml found, creating new file"
    fi
}

# Convert XPath to namespace-aware version using local-name()
namespace_aware_xpath() {
    local xpath="$1"
    # Convert /Configuration/element to /*[local-name()='Configuration']/*[local-name()='element']
    echo "$xpath" | sed -E 's|/([^/@\[]+)|/*[local-name()="\1"]|g'
}

# Function to fix common XSD validation issues
fix_validation_issues() {
    local file="$1"
    local fixed_issues=false
    
    echo "Attempting to fix common XSD validation issues..."
    
    # Fix duplicate certificateSigning elements (common issue)
    local cert_signing_count=$(xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='certificateSigning'])" "$file" 2>/dev/null || echo "0")
    if [[ "$cert_signing_count" -gt 1 ]]; then
        echo "Fixing duplicate certificateSigning elements (found $cert_signing_count)"
        # Keep only the first certificateSigning element
        xmlstarlet ed --inplace -d "/*[local-name()='Configuration']/*[local-name()='certificateSigning'][position()>1]" "$file" 2>/dev/null
        fixed_issues=true
    fi
    
    # Fix federation-server elements that might be missing required children
    if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server'])" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
        # Check if federation-server has webBaseUrl attribute (optional but recommended)
        if ! xmlstarlet sel -t -v "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/@webBaseUrl" "$file" 2>/dev/null | grep -q "."; then
            echo "Adding webBaseUrl attribute to federation-server"
            xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']" -t attr -n "webBaseUrl" -v "https://localhost:8443/Marti" "$file" 2>/dev/null
            fixed_issues=true
        fi
        
        # Ensure federation-server has required child elements
        if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'])" "$file" 2>/dev/null | grep -q "^0$"; then
            echo "Adding missing tls element to federation-server"
            xmlstarlet ed --inplace -s "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']" -t elem -n "tls" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keystore" -v "JKS" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keystoreFile" -v "/opt/tak/certs/files/takserver.jks" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keystorePass" -v "atakatak" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "truststore" -v "JKS" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "truststoreFile" -v "/opt/tak/certs/files/fed-truststore.jks" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "truststorePass" -v "atakatak" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keymanager" -v "SunX509" \
                "$file" 2>/dev/null
            fixed_issues=true
        fi
    fi
    
    # Remove invalid File element from auth section (common issue)
    if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='File'])" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
        echo "Removing invalid File element from auth section"
        xmlstarlet ed --inplace -d "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='File']" "$file" 2>/dev/null
        fixed_issues=true
    fi
    
    # Remove any other invalid empty elements in auth section
    xmlstarlet ed --inplace -d "/*[local-name()='Configuration']/*[local-name()='auth']/*[not(local-name()='ldap' or local-name()='oauth' or local-name()='file')]" "$file" 2>/dev/null || true
    
    # Remove any empty or malformed elements that might cause validation issues
    # Remove empty text nodes that might interfere with validation
    xmlstarlet ed --inplace -d "//text()[normalize-space(.)='']" "$file" 2>/dev/null || true
    
    if [[ "$fixed_issues" == "true" ]]; then
        echo "Applied fixes to resolve validation issues"
    else
        echo "No common validation issues found to fix"
    fi
}

# Function to create missing elements based on environment variables
create_missing_elements() {
    local file="$1"
    
    # Handle locate element specially since it requires a group attribute
    local locate_group="${TAKSERVER_CoreConfig_Locate_Group}"
    if [[ -n "$locate_group" ]]; then
        local ns_element=$(namespace_aware_xpath "/Configuration/locate")
        if ! xmlstarlet sel -t -v "count($ns_element)" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
            echo "Creating missing locate element with all attributes"
            xmlstarlet ed --inplace -s "/*[local-name()='Configuration']" -t elem -n "locate" \
                -i "/*[local-name()='Configuration']/*[local-name()='locate'][last()]" -t attr -n "group" -v "$locate_group" \
                -i "/*[local-name()='Configuration']/*[local-name()='locate'][last()]" -t attr -n "enabled" -v "$(get_env_value "TAKSERVER_CoreConfig_Locate_Enabled" "false" "boolean")" \
                -i "/*[local-name()='Configuration']/*[local-name()='locate'][last()]" -t attr -n "requireLogin" -v "$(get_env_value "TAKSERVER_CoreConfig_Locate_RequireLogin" "true" "boolean")" \
                -i "/*[local-name()='Configuration']/*[local-name()='locate'][last()]" -t attr -n "addToMission" -v "$(get_env_value "TAKSERVER_CoreConfig_Locate_AddToMission" "true" "boolean")" \
                -i "/*[local-name()='Configuration']/*[local-name()='locate'][last()]" -t attr -n "broadcast" -v "$(get_env_value "TAKSERVER_CoreConfig_Locate_Broadcast" "true" "boolean")" \
                -i "/*[local-name()='Configuration']/*[local-name()='locate'][last()]" -t attr -n "cot-type" -v "$(get_env_value "TAKSERVER_CoreConfig_Locate_CotType" "a-f-G")" \
                "$file"
            # Add mission attribute if provided
            locate_mission=$(get_env_value "TAKSERVER_CoreConfig_Locate_Mission" "")
            if [[ -n "$locate_mission" ]]; then
                xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='locate'][last()]" -t attr -n "mission" -v "$locate_mission" "$file"
            fi
        fi
    fi
    
    # Handle profile element specially since it has attributes
    local profile_streaming="${TAKSERVER_CoreConfig_Profile_UseStreamingGroup}"
    if [[ -n "$profile_streaming" ]]; then
        local ns_element=$(namespace_aware_xpath "/Configuration/profile")
        if ! xmlstarlet sel -t -v "count($ns_element)" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
            echo "Creating missing profile element with attributes"
            xmlstarlet ed --inplace -s "/*[local-name()='Configuration']" -t elem -n "profile" \
                -i "/*[local-name()='Configuration']/*[local-name()='profile'][last()]" -t attr -n "useStreamingGroup" -v "$(get_env_value "TAKSERVER_CoreConfig_Profile_UseStreamingGroup" "false" "boolean")" \
                "$file"
        fi
    fi
    
    # Define other optional elements and their trigger environment variables
    local -A optional_elements=(
        ["vbm"]="TAKSERVER_CoreConfig_Vbm_Enabled"
        ["plugins"]="TAKSERVER_CoreConfig_Plugins_UsePluginMessageQueue"
        ["cluster"]="TAKSERVER_CoreConfig_Cluster_Enabled"
        ["docs"]="TAKSERVER_CoreConfig_Docs_AdminOnly"
        ["logging"]="TAKSERVER_CoreConfig_Logging_JsonFormatEnabled"
    )
    
    # Check each optional element
    for element in "${!optional_elements[@]}"; do
        local trigger_var="${optional_elements[$element]}"
        if [[ -n "${!trigger_var}" ]]; then
            local ns_element=$(namespace_aware_xpath "/Configuration/$element")
            if ! xmlstarlet sel -t -v "count($ns_element)" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
                echo "Creating missing $element element"
                xmlstarlet ed --inplace -s "/*[local-name()='Configuration']" -t elem -n "$element" "$file"
            fi
        fi
    done
}

# Function to safely update XML with error handling
safe_xml_update() {
    local xpath="$1"
    local value="$2"
    local file="$3"
    local error_file="/tmp/xmlstarlet_error.log"
    
    # Convert to namespace-aware XPath
    local ns_xpath=$(namespace_aware_xpath "$xpath")
    
    # Check if the target node exists
    if ! xmlstarlet sel -t -v "count($ns_xpath)" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
        echo "Warning: XPath $xpath does not exist in the configuration file"
        echo "Will attempt to create the necessary structure"
        
        if [[ "$xpath" == */\@* ]]; then
            # This is an attribute, try to create parent element
            local element_path=$(echo "$xpath" | sed -E 's|/@[^/]+$||')
            local attr_name=$(echo "$xpath" | sed -E 's|.*/@([^/]+)$|\1|')
            local ns_element_path=$(namespace_aware_xpath "$element_path")
            
            # Check if parent element exists
            if ! xmlstarlet sel -t -v "count($ns_element_path)" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
                echo "Warning: Parent element for $xpath does not exist, cannot update"
                return 1
            fi
            
            # Add the attribute
            if ! xmlstarlet ed --inplace -s "$ns_element_path" -t attr -n "$attr_name" -v "$value" "$file" 2>"$error_file"; then
                echo "Warning: Failed to create attribute $attr_name"
                echo "xmlstarlet error:"
                cat "$error_file"
                return 1
            fi
            return 0
        fi
    fi
    
    # Update the existing node
    if ! xmlstarlet ed --inplace -u "$ns_xpath" -v "$value" "$file" 2>"$error_file"; then
        echo "Warning: Failed to update $xpath in configuration file"
        echo "xmlstarlet error:"
        cat "$error_file"
        return 1
    fi
    return 0
}

# Function to handle array elements (elements that can appear multiple times)
update_array_element() {
    local base_xpath="$1"      # Base path to the element type
    local id_attr="$2"         # Attribute used to identify the specific element
    local id_value="$3"        # Value of the identifier attribute
    local target_attr="$4"     # Attribute to update
    local new_value="$5"       # New value to set
    local file="$6"            # File to update
    local error_file="/tmp/xmlstarlet_error.log"
    
    # Convert to namespace-aware XPath
    local ns_base_xpath=$(namespace_aware_xpath "$base_xpath")
    
    # Check if the element exists
    if xmlstarlet sel -t -v "count($ns_base_xpath[@$id_attr='$id_value'])" "$file" 2>/dev/null | grep -q "^0$"; then
        # Element doesn't exist, try to create it
        echo "Array element $base_xpath[@$id_attr='$id_value'] not found, attempting to create it"
        
        # Get parent element path
        local parent_path=$(echo "$base_xpath" | sed -E 's|/[^/]+$||')
        local element_name=$(echo "$base_xpath" | sed -E 's|.*/([^/]+)$|\1|')
        local ns_parent_path=$(namespace_aware_xpath "$parent_path")
        
        # Check if parent exists
        if ! xmlstarlet sel -t -v "count($ns_parent_path)" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
            echo "Warning: Parent element $parent_path does not exist, cannot create array element"
            return 1
        fi
        
        # Create the element with identifier attribute
        if ! xmlstarlet ed --inplace -s "$ns_parent_path" -t elem -n "$element_name" \
                -i "$ns_parent_path/$element_name[last()]" -t attr -n "$id_attr" -v "$id_value" \
                -i "$ns_parent_path/$element_name[last()]" -t attr -n "$target_attr" -v "$new_value" \
                "$file" 2>"$error_file"; then
            echo "Warning: Failed to create array element $base_xpath[@$id_attr='$id_value']"
            echo "xmlstarlet error:"
            cat "$error_file"
            return 1
        fi
        
        echo "Successfully created array element $base_xpath[@$id_attr='$id_value']"
        return 0
    fi
    
    # Update the existing element
    if ! xmlstarlet ed --inplace -u "$ns_base_xpath[@$id_attr='$id_value']/@$target_attr" -v "$new_value" "$file" 2>"$error_file"; then
        echo "Warning: Failed to update array element $base_xpath[@$id_attr='$id_value']/@$target_attr"
        echo "xmlstarlet error:"
        cat "$error_file"
        return 1
    fi
    
    return 0
}

# Enable debug mode if requested
DEBUG=${DEBUG:-false}
if [[ "${DEBUG,,}" == "true" ]]; then
    set -x
    echo "Debug mode enabled"
fi

# Set commonly used values
LETSENCRYPT_DOMAIN=$(get_env_value "TAKSERVER_QuickConnect_LetsEncrypt_Domain" "nodomainset")
SERVER_ID=$(cat /proc/sys/kernel/random/uuid)

# Download and setup AWS Root CA
curl -s --max-time 30 --fail https://www.amazontrust.com/repository/AmazonRootCA1.pem > /tmp/AmazonRootCA1.pem
echo "yes" | keytool -import -file /tmp/AmazonRootCA1.pem -alias AWS -deststoretype JKS -deststorepass INTENTIONALLY_NOT_SENSITIVE -keystore /tmp/AmazonRootCA1.jks >/dev/null 2>&1
cp /tmp/AmazonRootCA1.jks /opt/tak/certs/files/aws-acm-root.jks

# Check for existing file
check_existing_file

# Print environment variables that will affect configuration (debug only)
if [[ "${DEBUG,,}" == "true" ]]; then
    echo "Environment variables affecting CoreConfig.xml:"
    env | grep -E "^TAKSERVER_CoreConfig_" | sort
    echo "Default values from project-defaults.env:"
    env | grep -E "^TAKSERVER_CoreConfig_.*_DEFAULT" | sort
fi

# Build network attributes
allow_origins_attr=$(add_attr "allowAllOrigins" "$(get_env_value "TAKSERVER_CoreConfig_Network_AllowAllOrigins" "false" "boolean")" "false")
enable_hsts_attr=$(add_attr "enableHSTS" "$(get_env_value "TAKSERVER_CoreConfig_Network_EnableHSTS" "true" "boolean")" "true")
mission_groups_attr="MissionUseGroupsForContents=\"$(get_env_value "TAKSERVER_CoreConfig_Network_MissionUseGroupsForContents" "false" "boolean")\""
mission_change_attr="MissionAllowGroupChange=\"$(get_env_value "TAKSERVER_CoreConfig_Network_MissionAllowGroupChange" "false" "boolean")\""

# Generate temporary CoreConfig.xml
cat > "$TEMP_FILE" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Configuration xmlns="http://bbn.com/marti/xml/config">
    <network multicastTTL="5" serverId="${SERVER_ID}" version="${TAK_VERSION#takserver-docker-}" cloudwatchEnable="$(get_env_value "TAKSERVER_CoreConfig_Network_CloudwatchEnable" "false" "boolean")" cloudwatchName="${StackName}"${allow_origins_attr}${enable_hsts_attr} ${mission_groups_attr} ${mission_change_attr}>
        <input auth="$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Auth" "x509")" _name="stdssl" protocol="tls" port="8089" coreVersion="2"$(add_attr "archive" "$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Archive" "true" "boolean")" "true")/>
        <connector port="8443" _name="https" keystore="JKS" keystoreFile="/opt/tak/certs/files/${LETSENCRYPT_DOMAIN}/letsencrypt.jks" keystorePass="atakatak"$(add_attr "enableAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI" "true" "boolean")" "false")$(add_attr "enableWebtak" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak" "true" "boolean")" "false")$(add_attr "enableNonAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableNonAdminUI" "true" "boolean")" "false")/>
        <connector port="8446" clientAuth="false" _name="cert_https" keystore="JKS" keystoreFile="/opt/tak/certs/files/${LETSENCRYPT_DOMAIN}/letsencrypt.jks" keystorePass="atakatak"$(add_attr "enableAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableAdminUI" "true" "boolean")" "false")$(add_attr "enableWebtak" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak" "true" "boolean")" "false")$(add_attr "enableNonAdminUI" "$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableNonAdminUI" "true" "boolean")" "false")/>
        <announce$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Network_Announce_Enable" "false" "boolean")" "false")/>
    </network>
    <auth default="$(get_env_value "TAKSERVER_CoreConfig_Auth_Default" "ldap")"$(add_attr "x509groups" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509groups" "true" "boolean")" "false")$(add_attr "x509addAnonymous" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509addAnonymous" "false" "boolean")" "true")$(add_attr "x509useGroupCache" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCache" "true" "boolean")" "false")$(add_attr "x509useGroupCacheDefaultActive" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive" "true" "boolean")" "false")$(add_attr "x509checkRevocation" "$(get_env_value "TAKSERVER_CoreConfig_Auth_X509checkRevocation" "true" "boolean")" "false")>
        <ldap url="${LDAP_SECURE_URL}" userstring="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Userstring" "cn={username},ou=users,")${LDAP_DN}" updateinterval="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Updateinterval" "60")"$(add_attr_always "groupprefix" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix")")$(add_attr_always "groupNameExtractorRegex" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex")")$(add_attr "style" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Style" "DS")" "DS") serviceAccountDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_ServiceAccountDN" "cn=ldapservice,ou=users,")${LDAP_DN}" serviceAccountCredential="${LDAP_Password}"$(add_attr "groupObjectClass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass" "group")" "group")$(add_attr "userObjectClass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_UserObjectClass" "user")" "user") groupBaseRDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupBaseRDN" "ou=groups,")${LDAP_DN}" userBaseRDN="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_UserBaseRDN" "ou=users,")${LDAP_DN}"$(add_attr "nestedGroupLookup" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_NestedGroupLookup" "false" "boolean")" "false")$(add_attr_always "ldapsTruststore" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststore" "JKS")")$(add_attr_always "ldapsTruststoreFile" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststoreFile" "/opt/tak/certs/files/aws-acm-root.jks")")$(add_attr_always "ldapsTruststorePass" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_LdapsTruststorePass" "INTENTIONALLY_NOT_SENSITIVE")") callsignAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_CallsignAttribute" "takCallsign")" colorAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_ColorAttribute" "takColor")" roleAttribute="$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_RoleAttribute" "takRole")"$(add_attr "enableConnectionPool" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_EnableConnectionPool" "false" "boolean")" "false")$(add_attr "dnAttributeName" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_DnAttributeName" "DN")" "distinguishedName")$(add_attr "nameAttr" "$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_NameAttr" "CN")" "cn")/>
EOF

# Add OAuth section if OAuth server is configured
oauth_server_name=$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Name" "")
if [[ -n "$oauth_server_name" ]]; then
    cat >> "$TEMP_FILE" << EOF
        <oauth$(add_attr "oauthUseGroupCache" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_OauthUseGroupCache" "false" "boolean")" "false")$(add_attr "loginWithEmail" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_LoginWithEmail" "false" "boolean")" "false")$(add_attr "useTakServerLoginPage" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_UseTakServerLoginPage" "false" "boolean")" "false")$(add_attr "allowUriQueryParameter" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_AllowUriQueryParameter" "false" "boolean")" "false")$(add_attr "groupsClaim" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_GroupsClaim" "groups")" "groups")$(add_attr_always "groupprefix" "$(get_env_value "TAKSERVER_CoreConfig_OAuth_Groupprefix")")>
EOF
    
    # Add optional OAuth child elements
    groups_claim=$(get_env_value "TAKSERVER_CoreConfig_OAuth_GroupsClaim" "")
    username_claim=$(get_env_value "TAKSERVER_CoreConfig_OAuth_UsernameClaim" "")
    scope_claim=$(get_env_value "TAKSERVER_CoreConfig_OAuth_ScopeClaim" "")
    webtak_scope=$(get_env_value "TAKSERVER_CoreConfig_OAuth_WebtakScope" "")
    group_prefix=$(get_env_value "TAKSERVER_CoreConfig_OAuth_Groupprefix" "")
    
    [[ -n "$groups_claim" && "$groups_claim" != "groups" ]] && echo "            <groupsClaim>$groups_claim</groupsClaim>" >> "$TEMP_FILE"
    [[ -n "$username_claim" ]] && echo "            <usernameClaim>$username_claim</usernameClaim>" >> "$TEMP_FILE"
    [[ -n "$scope_claim" && "$scope_claim" != "scope" ]] && echo "            <scopeClaim>$scope_claim</scopeClaim>" >> "$TEMP_FILE"
    [[ -n "$webtak_scope" ]] && echo "            <webtakScope>$webtak_scope</webtakScope>" >> "$TEMP_FILE"
    [[ -n "$group_prefix" ]] && echo "            <groupprefix>$group_prefix</groupprefix>" >> "$TEMP_FILE"
    
    # Add OAuth server configuration
    cat >> "$TEMP_FILE" << EOF
            <authServer name="$oauth_server_name" issuer="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Issuer" "")" clientId="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_ClientId" "")" secret="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Secret" "")" redirectUri="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RedirectUri" "")" scope="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Scope" "")" authEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint" "")" tokenEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint" "")"$(add_attr "accessTokenName" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AccessTokenName" "access_token")" "access_token")$(add_attr "refreshTokenName" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RefreshTokenName" "refresh_token")" "refresh_token")$(add_attr "trustAllCerts" "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts" "false" "boolean")" "false")/>
EOF
    echo "        </oauth>" >> "$TEMP_FILE"
fi

# Complete the auth section and add remaining sections
cat >> "$TEMP_FILE" << EOF
    </auth>
    <submission$(add_attr_always "ignoreStaleMessages" "$(get_env_value "TAKSERVER_CoreConfig_Submission_IgnoreStaleMessages" "false" "boolean")")$(add_attr "validateXml" "$(get_env_value "TAKSERVER_CoreConfig_Submission_ValidateXml" "false" "boolean")" "false")/>
    <subscription$(add_attr "reloadPersistent" "$(get_env_value "TAKSERVER_CoreConfig_Subscription_ReloadPersistent" "false" "boolean")" "false")/>
    <repository$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Repository_Enable" "true" "boolean")" "false")$(add_attr "numDbConnections" "$(get_env_value "TAKSERVER_CoreConfig_Repository_NumDbConnections" "16")" "16")$(add_attr "primaryKeyBatchSize" "$(get_env_value "TAKSERVER_CoreConfig_Repository_PrimaryKeyBatchSize" "500")" "500")$(add_attr "insertionBatchSize" "$(get_env_value "TAKSERVER_CoreConfig_Repository_InsertionBatchSize" "500")" "500")>
        <connection url="${PostgresURL}" username="${PostgresUsername}" password="${PostgresPassword}"/>
    </repository>
    <repeater$(add_attr "enable" "$(get_env_value "TAKSERVER_CoreConfig_Repeater_Enable" "true" "boolean")" "false")$(add_attr "periodMillis" "$(get_env_value "TAKSERVER_CoreConfig_Repeater_PeriodMillis" "3000")" "3000")$(add_attr "staleDelayMillis" "$(get_env_value "TAKSERVER_CoreConfig_Repeater_StaleDelayMillis" "15000")" "15000")>
EOF

# Add repeatable types if repeater is enabled
if [[ "$(get_env_value "TAKSERVER_CoreConfig_Repeater_Enable" "true" "boolean")" == "true" ]]; then
    cat >> "$TEMP_FILE" << EOF
        <repeatableType initiate-test="/event/detail/emergency[@type='911 Alert']" cancel-test="/event/detail/emergency[@cancel='true']" _name="911"/>
        <repeatableType initiate-test="/event/detail/emergency[@type='Ring The Bell']" cancel-test="/event/detail/emergency[@cancel='true']" _name="RingTheBell"/>
        <repeatableType initiate-test="/event/detail/emergency[@type='Geo-fence Breached']" cancel-test="/event/detail/emergency[@cancel='true']" _name="GeoFenceBreach"/>
        <repeatableType initiate-test="/event/detail/emergency[@type='Troops In Contact']" cancel-test="/event/detail/emergency[@cancel='true']" _name="TroopsInContact"/>
EOF
fi

cat >> "$TEMP_FILE" << EOF
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
        <queue defaultCoreMaxPoolFactor="$(get_env_value "TAKSERVER_CoreConfig_Queue_DefaultCoreMaxPoolFactor" "2")">
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

# Note: Certificate signing section is already included above - no duplicate needed

cat >> "$TEMP_FILE" << EOF
    <security>
        <tls keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_KeystoreFile" "/opt/tak/certs/files/takserver.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_KeystorePass" "atakatak")" truststore="JKS" truststoreFile="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_TruststoreFile" "/opt/tak/certs/files/truststore-intermediate-ca.jks")" truststorePass="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_TruststorePass" "atakatak")" keymanager="$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_Keymanager" "SunX509")"$(add_attr_always "context" "$(get_env_value "TAKSERVER_CoreConfig_Security_TLS_Context")")/>
EOF

# Add mission TLS if configured
if [[ -n "$(get_env_value "TAKSERVER_CoreConfig_Security_MissionTLS_KeystoreFile" "")" ]]; then
    cat >> "$TEMP_FILE" << EOF
        <missionTls keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_Security_MissionTLS_KeystoreFile" "/opt/tak/certs/files/truststore-root.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_Security_MissionTLS_KeystorePass" "atakatak")"/>
EOF
fi

# Check if federation is enabled
federation_enabled=$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableFederation" "true" "boolean")

cat >> "$TEMP_FILE" << EOF
    </security>
    <federation$(add_attr "allowFederatedDelete" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowFederatedDelete" "false" "boolean")" "false")$(add_attr "allowMissionFederation" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowMissionFederation" "true" "boolean")" "false")$(add_attr "allowDataFeedFederation" "$(get_env_value "TAKSERVER_CoreConfig_Federation_AllowDataFeedFederation" "true" "boolean")" "false")$(add_attr "enableMissionFederationDisruptionTolerance" "$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableMissionFederationDisruptionTolerance" "true" "boolean")" "false") missionFederationDisruptionToleranceRecencySeconds="$(get_env_value "TAKSERVER_CoreConfig_Federation_MissionFederationDisruptionToleranceRecencySeconds" "43200")" enableFederation="$federation_enabled"$(add_attr "enableDataPackageAndMissionFileFilter" "$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableDataPackageAndMissionFileFilter" "false" "boolean")" "false")>
EOF

# Only add federation-server if federation is enabled
if [[ "$federation_enabled" == "true" ]]; then
    cat >> "$TEMP_FILE" << EOF
        <federation-server port="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_Port" "9000")">
            <tls context="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_Context" "TLSv1.2")" keymanager="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_Keymanager" "SunX509")" keystore="JKS" keystoreFile="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_KeystoreFile" "/opt/tak/certs/files/takserver.jks")" keystorePass="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_KeystorePass" "atakatak")" truststore="JKS" truststoreFile="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_TruststoreFile" "/opt/tak/certs/files/fed-truststore.jks")" truststorePass="$(get_env_value "TAKSERVER_CoreConfig_Federation_Server_TLS_TruststorePass" "atakatak")"/>
        </federation-server>
EOF
fi
# Add fileFilter section
cat >> "$TEMP_FILE" << EOF
        <fileFilter>
EOF

# Add file extensions if configured
file_extensions=$(get_env_value "TAKSERVER_CoreConfig_Federation_FileFilter_Extensions" "pref")
if [[ -n "$file_extensions" ]]; then
    IFS=',' read -ra EXTENSIONS <<< "$file_extensions"
    for ext in "${EXTENSIONS[@]}"; do
        echo "            <fileExtension>$ext</fileExtension>" >> "$TEMP_FILE"
    done
fi

cat >> "$TEMP_FILE" << EOF
        </fileFilter>
    </federation>
    <plugins/>
    <cluster metricsIntervalSeconds="$(get_env_value "TAKSERVER_CoreConfig_Cluster_MetricsIntervalSeconds" "2147483646")"/>
    <vbm/>
    <profile$(add_attr "useStreamingGroup" "$(get_env_value "TAKSERVER_CoreConfig_Profile_UseStreamingGroup" "false" "boolean")" "false")/>
EOF

# Add locate element if group is provided (required by XSD)
locate_group=$(get_env_value "TAKSERVER_CoreConfig_Locate_Group" "")
if [[ -n "$locate_group" ]]; then
    cat >> "$TEMP_FILE" << EOF
    <locate$(add_attr "enabled" "$(get_env_value "TAKSERVER_CoreConfig_Locate_Enabled" "false" "boolean")" "false")$(add_attr "requireLogin" "$(get_env_value "TAKSERVER_CoreConfig_Locate_RequireLogin" "true" "boolean")" "true")$(add_attr "cot-type" "$(get_env_value "TAKSERVER_CoreConfig_Locate_CotType" "a-f-G")" "a-f-G") group="$locate_group"$(add_attr "broadcast" "$(get_env_value "TAKSERVER_CoreConfig_Locate_Broadcast" "true" "boolean")" "true")$(add_attr "addToMission" "$(get_env_value "TAKSERVER_CoreConfig_Locate_AddToMission" "true" "boolean")" "true")$(add_attr_always "mission" "$(get_env_value "TAKSERVER_CoreConfig_Locate_Mission" "")")/>
EOF
fi

cat >> "$TEMP_FILE" << EOF
</Configuration>
EOF

# Work on temporary file to avoid writing invalid config to disk
WORK_FILE=$(mktemp)

# Merge configurations if existing file is found
if [[ -n "$EXISTING_FILE" ]]; then
    echo "Merging environment-driven settings with existing configuration"
    
    # Create working file from existing
    cp "$EXISTING_FILE" "$WORK_FILE"
    
    # Immediately remove any invalid federation-token-authentication elements that might exist
    echo "Performing early cleanup of invalid federation elements"
    xmlstarlet ed --inplace -d "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='federation-token-authentication']" "$WORK_FILE" 2>/dev/null || true
    
    # Fix any validation issues in the existing configuration
    fix_validation_issues "$WORK_FILE"
    
    # Apply critical settings that must be preserved
    if ! safe_xml_update "/Configuration/network/@serverId" "${SERVER_ID}" "$WORK_FILE"; then
        echo "Warning: Failed to update server ID, continuing with existing value"
    fi
    
    # Extract just the version number from TAK_VERSION (remove takserver-docker- prefix)
    CLEAN_TAK_VERSION="${TAK_VERSION#takserver-docker-}"
    if ! safe_xml_update "/Configuration/network/@version" "${CLEAN_TAK_VERSION}" "$WORK_FILE"; then
        echo "Warning: Failed to update TAK version, continuing with existing value"
    fi
    
    # Apply database connection settings (always required)
    if ! safe_xml_update "/Configuration/repository/connection/@url" "${PostgresURL}" "$WORK_FILE"; then
        echo "Error: Failed to update database URL, this is critical for operation"
    fi
    
    if ! safe_xml_update "/Configuration/repository/connection/@username" "${PostgresUsername}" "$WORK_FILE"; then
        echo "Error: Failed to update database username, this is critical for operation"
    fi
    
    if ! safe_xml_update "/Configuration/repository/connection/@password" "${PostgresPassword}" "$WORK_FILE"; then
        echo "Error: Failed to update database password, this is critical for operation"
    fi
    
    # Apply LDAP settings (always required)
    if ! safe_xml_update "/Configuration/auth/ldap/@url" "${LDAP_SECURE_URL}" "$WORK_FILE"; then
        echo "Warning: Failed to update LDAP URL, continuing with existing value"
    fi
    
    if ! safe_xml_update "/Configuration/auth/ldap/@serviceAccountCredential" "${LDAP_Password}" "$WORK_FILE"; then
        echo "Warning: Failed to update LDAP password, continuing with existing value"
    fi
    
    # Force re-apply all CDK environment variables and secrets on every restart
    echo "Force applying all CDK environment variables to existing configuration"
    
    # Core infrastructure settings
    [[ -n "$StackName" ]] && safe_xml_update "/Configuration/network/@cloudwatchName" "$StackName" "$WORK_FILE"
    
    # LDAP settings from CDK
    [[ -n "$LDAP_DN" ]] && safe_xml_update "/Configuration/auth/ldap/@userstring" "cn={username},ou=users,$LDAP_DN" "$WORK_FILE"
    [[ -n "$LDAP_DN" ]] && safe_xml_update "/Configuration/auth/ldap/@serviceAccountDN" "cn=ldapservice,ou=users,$LDAP_DN" "$WORK_FILE"
    [[ -n "$LDAP_DN" ]] && safe_xml_update "/Configuration/auth/ldap/@groupBaseRDN" "ou=groups,$LDAP_DN" "$WORK_FILE"
    [[ -n "$LDAP_DN" ]] && safe_xml_update "/Configuration/auth/ldap/@userBaseRDN" "ou=users,$LDAP_DN" "$WORK_FILE"
    
    # LDAP Group Prefix Configuration from CDK
    ldap_group_prefix=$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix" "")
    if [[ -n "$ldap_group_prefix" ]]; then
        echo "Applying LDAP group prefix: $ldap_group_prefix"
        safe_xml_update "/Configuration/auth/ldap/@groupprefix" "$ldap_group_prefix" "$WORK_FILE"
    fi
    
    ldap_group_regex=$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex" "")
    if [[ -n "$ldap_group_regex" ]]; then
        echo "Applying LDAP group name extractor regex: $ldap_group_regex"
        safe_xml_update "/Configuration/auth/ldap/@groupNameExtractorRegex" "$ldap_group_regex" "$WORK_FILE"
    fi
    
    # CloudWatch settings from CDK
    cloudwatch_enable=$(get_env_value "TAKSERVER_CoreConfig_Network_CloudwatchEnable" "false")
    safe_xml_update "/Configuration/network/@cloudwatchEnable" "$cloudwatch_enable" "$WORK_FILE"
    
    # Let's Encrypt settings from CDK
    letsencrypt_domain=$(get_env_value "TAKSERVER_QuickConnect_LetsEncrypt_Domain" "")
    if [[ -n "$letsencrypt_domain" ]]; then
        safe_xml_update "/Configuration/network/connector[@port='8443']/@keystoreFile" "/opt/tak/certs/files/$letsencrypt_domain/letsencrypt.jks" "$WORK_FILE"
        safe_xml_update "/Configuration/network/connector[@port='8446']/@keystoreFile" "/opt/tak/certs/files/$letsencrypt_domain/letsencrypt.jks" "$WORK_FILE"
    fi
    
    # Always recreate OAuth section from CDK environment variables (ignore existing config)
    oauth_server_name=$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Name" "")
    
    # Remove existing OAuth section if it exists
    if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth'])" "$WORK_FILE" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
        echo "Removing existing OAuth section to recreate from CDK environment variables"
        xmlstarlet ed --inplace -d "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']" "$WORK_FILE" 2>/dev/null
    fi
    
    # Create OAuth section if OAuth server is configured in CDK
    if [[ -n "$oauth_server_name" ]]; then
        echo "Creating OAuth section from CDK environment variables"
        
        # Create OAuth element using xmlstarlet
        if ! xmlstarlet ed --inplace -s "/*[local-name()='Configuration']/*[local-name()='auth']" -t elem -n "oauth" "$WORK_FILE" 2>/dev/null; then
            echo "Warning: Failed to create OAuth element"
        else
            # Add OAuth attributes from CDK
            [[ "$(get_env_value "TAKSERVER_CoreConfig_OAuth_OauthUseGroupCache" "false" "boolean")" == "true" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth'][last()]" -t attr -n "oauthUseGroupCache" -v "true" "$WORK_FILE" 2>/dev/null
            [[ "$(get_env_value "TAKSERVER_CoreConfig_OAuth_LoginWithEmail" "false" "boolean")" == "true" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth'][last()]" -t attr -n "loginWithEmail" -v "true" "$WORK_FILE" 2>/dev/null
            [[ "$(get_env_value "TAKSERVER_CoreConfig_OAuth_UseTakServerLoginPage" "false" "boolean")" == "true" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth'][last()]" -t attr -n "useTakServerLoginPage" -v "true" "$WORK_FILE" 2>/dev/null
            [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuth_UsernameClaim" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth'][last()]" -t attr -n "usernameClaim" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuth_UsernameClaim" "")" "$WORK_FILE" 2>/dev/null
            [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuth_Groupprefix" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth'][last()]" -t attr -n "groupprefix" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuth_Groupprefix" "")" "$WORK_FILE" 2>/dev/null
            
            # Create authServer element with CDK values
            if ! xmlstarlet ed --inplace -s "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']" -t elem -n "authServer" "$WORK_FILE" 2>/dev/null; then
                echo "Warning: Failed to create authServer element"
            else
                # Add authServer attributes from CDK
                xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "name" -v "$oauth_server_name" "$WORK_FILE" 2>/dev/null
                [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Issuer" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "issuer" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Issuer" "")" "$WORK_FILE" 2>/dev/null
                [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_ClientId" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "clientId" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_ClientId" "")" "$WORK_FILE" 2>/dev/null
                [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Secret" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "secret" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Secret" "")" "$WORK_FILE" 2>/dev/null
                [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RedirectUri" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "redirectUri" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RedirectUri" "")" "$WORK_FILE" 2>/dev/null
                [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Scope" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "scope" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Scope" "")" "$WORK_FILE" 2>/dev/null
                [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "authEndpoint" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint" "")" "$WORK_FILE" 2>/dev/null
                [[ -n "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint" "")" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "tokenEndpoint" -v "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint" "")" "$WORK_FILE" 2>/dev/null

                [[ "$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts" "false" "boolean")" == "true" ]] && xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='auth']/*[local-name()='oauth']/*[local-name()='authServer'][last()]" -t attr -n "trustAllCerts" -v "true" "$WORK_FILE" 2>/dev/null
                # Note: TAKSERVER_CoreConfig_OAuthServer_JWKS is used by getOIDCIssuerPubKey.sh, not CoreConfig.xml
                echo "OAuth section created successfully from CDK environment variables"
            fi
        fi
    else
        echo "No OAuth server configured in CDK - OAuth section will not be created"
    fi
    
    # Fix federation-server element structure to match XSD requirements
    if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server'])" "$WORK_FILE" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
        echo "Checking federation-server element for XSD compliance"
        
        # Remove ALL invalid child elements from federation-server first
        # According to XSD, federation-server should only contain: tls, federation-port, v1Tls
        echo "Removing all invalid child elements from federation-server"
        xmlstarlet ed --inplace -d "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[not(local-name()='tls' or local-name()='federation-port' or local-name()='v1Tls')]" "$WORK_FILE" 2>/dev/null || true
        
        # Ensure federation-server has the required tls child element
        if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'])" "$WORK_FILE" 2>/dev/null | grep -q "^0$"; then
            echo "Adding missing tls element to federation-server"
            xmlstarlet ed --inplace -s "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']" -t elem -n "tls" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "context" -v "TLSv1.2" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keymanager" -v "SunX509" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keystore" -v "JKS" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keystoreFile" -v "/opt/tak/certs/files/takserver.jks" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "keystorePass" -v "atakatak" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "truststore" -v "JKS" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "truststoreFile" -v "/opt/tak/certs/files/fed-truststore.jks" \
                -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'][last()]" -t attr -n "truststorePass" -v "atakatak" \
                "$WORK_FILE" 2>/dev/null
        fi
    fi
    
    # Create missing elements based on environment variables
    create_missing_elements "$WORK_FILE"
    
    # Fix existing locate element attributes from environment variables
    locate_group=$(get_env_value "TAKSERVER_CoreConfig_Locate_Group" "")
    if [[ -n "$locate_group" ]]; then
        ns_locate=$(namespace_aware_xpath "/Configuration/locate")
        if xmlstarlet sel -t -v "count($ns_locate)" "$WORK_FILE" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
            echo "Updating locate element attributes from environment variables"
            safe_xml_update "/Configuration/locate/@group" "$locate_group" "$WORK_FILE"
            safe_xml_update "/Configuration/locate/@enabled" "$(get_env_value "TAKSERVER_CoreConfig_Locate_Enabled" "false" "boolean")" "$WORK_FILE"
            safe_xml_update "/Configuration/locate/@requireLogin" "$(get_env_value "TAKSERVER_CoreConfig_Locate_RequireLogin" "true" "boolean")" "$WORK_FILE"
            safe_xml_update "/Configuration/locate/@addToMission" "$(get_env_value "TAKSERVER_CoreConfig_Locate_AddToMission" "true" "boolean")" "$WORK_FILE"
            safe_xml_update "/Configuration/locate/@broadcast" "$(get_env_value "TAKSERVER_CoreConfig_Locate_Broadcast" "true" "boolean")" "$WORK_FILE"
            safe_xml_update "/Configuration/locate/@cot-type" "$(get_env_value "TAKSERVER_CoreConfig_Locate_CotType" "a-f-G")" "$WORK_FILE"
            locate_mission=$(get_env_value "TAKSERVER_CoreConfig_Locate_Mission" "")
            [[ -n "$locate_mission" ]] && safe_xml_update "/Configuration/locate/@mission" "$locate_mission" "$WORK_FILE"
        fi
    fi
    
    # Fix existing profile element attributes from environment variables
    profile_streaming=$(get_env_value "TAKSERVER_CoreConfig_Profile_UseStreamingGroup" "")
    if [[ -n "$profile_streaming" ]]; then
        ns_profile=$(namespace_aware_xpath "/Configuration/profile")
        if xmlstarlet sel -t -v "count($ns_profile)" "$WORK_FILE" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
            echo "Updating profile element attributes from environment variables"
            safe_xml_update "/Configuration/profile/@useStreamingGroup" "$(get_env_value "TAKSERVER_CoreConfig_Profile_UseStreamingGroup" "false" "boolean")" "$WORK_FILE"
        fi
    fi
    
    # Apply environment-driven settings
    for xpath in "${!ENV_DRIVEN_SETTINGS[@]}"; do
        env_var="${ENV_DRIVEN_SETTINGS[$xpath]}"
        value="${!env_var}"
        
        # Skip empty values
        if [[ -z "$value" ]]; then
            continue
        fi
        
        # Handle special case for array elements
        if [[ "$xpath" == *"[@"*"]"* ]]; then
            # This is an array element with an identifier
            base_xpath=$(echo "$xpath" | sed -E 's/\[@.*\].*$//')
            id_attr=$(echo "$xpath" | sed -E 's/.*\[@([^=]+)=.*/\1/')
            id_value=$(echo "$xpath" | sed -E 's/.*\[@[^=]+=.([^]]+).].*/\1/')
            target_attr=$(echo "$xpath" | sed -E 's/.*\]@([^=]+)$/\1/')
            
            update_array_element "$base_xpath" "$id_attr" "$id_value" "$target_attr" "$value" "$WORK_FILE"
            continue
        fi
        
        # Extract the value from the temporary file
        if xpath_value=$(xmlstarlet sel -t -v "$xpath" "$TEMP_FILE" 2>/dev/null); then
            # Apply the value to the output file if it exists
            if [[ -n "$xpath_value" ]]; then
                echo "Applying environment setting $env_var to $xpath"
                if ! safe_xml_update "$xpath" "$xpath_value" "$WORK_FILE"; then
                    echo "Warning: Failed to update $xpath with value from $env_var"
                fi
            fi
        fi
    done
else
    # No existing file, use the temporary file directly
    cp "$TEMP_FILE" "$WORK_FILE"
fi

# Validate working file before writing to final location
if [[ -f "/opt/tak/CoreConfig.xsd" ]]; then
    echo "Validating generated CoreConfig.xml against XSD schema..."
    if ! xmlstarlet val -s "/opt/tak/CoreConfig.xsd" "$WORK_FILE" 2>/tmp/validation_error.log; then
        echo "ERROR: Generated CoreConfig.xml fails XSD validation - detailed errors:"
        cat /tmp/validation_error.log
        echo ""
        echo "Attempting to get more specific validation details..."
        # Try xmllint for more detailed error reporting
        xmllint --schema "/opt/tak/CoreConfig.xsd" "$WORK_FILE" --noout 2>/tmp/xmllint_error.log || true
        echo "XMLLint validation errors:"
        cat /tmp/xmllint_error.log
        echo ""
        echo "Generated XML content (first 50 lines):"
        head -50 "$WORK_FILE"
        echo ""
        echo "Checking for specific problematic elements..."
        echo "Federation-server child elements:"
        xmlstarlet sel -t -m "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*" -v "local-name()" -n "$WORK_FILE" 2>/dev/null || echo "No federation-server found"
        echo "ERROR: Not writing invalid CoreConfig.xml to disk"
        rm -f "$WORK_FILE"
        exit 1
    else
        echo "CoreConfig.xml validation passed"
    fi
fi

# Only write to final location if validation passes
cp "$WORK_FILE" "$OUTPUT_FILE"

# Clean up
rm -f "$TEMP_FILE" "$WORK_FILE"

echo "TAK Server - CoreConfig.xml generated successfully at $OUTPUT_FILE"