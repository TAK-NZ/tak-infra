#!/bin/bash
#
# Generates /opt/tak/CoreConfig.xml on every container start.
#
# Design: CoreConfig.xml is always rebuilt fresh from the version-specific
# template plus CDK/S3-provided environment variables. This makes S3
# (takserver-config.env) and CDK context the single source of truth for
# every section of the file EXCEPT <federation>.
#
# <federation> is the one section TAK Server itself writes back to disk at
# runtime (e.g. adding an outgoing federation connection via the admin UI
# calls setAndSaveFederation(), which re-serializes the whole element).
# Any admin-made federation change would be silently destroyed by a full
# regeneration, so the existing <federation> subtree (if present) is always
# preserved by copying it verbatim into the freshly generated file.
#
# Every other CoreConfig.xml section (auth, filter, security, etc.) is
# considered fully S3/CDK-managed: if you change something in the admin UI
# outside of federation, it WILL be reverted on the next container restart.
# This is intentional -- see docs/TAKSERVER_CORECONFIG.md.

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

# Check if an existing CoreConfig.xml is present and structurally valid.
# Only used to source the preserved <federation> subtree -- everything else
# in the file is always regenerated fresh.
check_existing_file() {
    if [[ -f "$OUTPUT_FILE" ]]; then
        if xmlstarlet val -q "$OUTPUT_FILE"; then
            EXISTING_FILE="$OUTPUT_FILE"
            echo "Found existing valid CoreConfig.xml; will preserve its <federation> configuration"
            # Create a backup of the existing file
            cp "$OUTPUT_FILE" "${OUTPUT_FILE}.bak"
        else
            echo "Warning: Existing CoreConfig.xml is not valid XML, cannot preserve federation config"
        fi
    else
        echo "No existing CoreConfig.xml found"
    fi
}

# Convert XPath to namespace-aware version using local-name()
namespace_aware_xpath() {
    local xpath="$1"
    # Convert /Configuration/element to /*[local-name()='Configuration']/*[local-name()='element']
    echo "$xpath" | sed -E 's|/([^/@\[]+)|/*[local-name()="\1"]|g'
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

# Preserve the existing <federation> element (if any) by splicing it into the
# freshly generated file, replacing whatever federation content the template
# produced. This is the one section of CoreConfig.xml that TAK Server itself
# writes back to disk at runtime (admin UI federation config, outgoing
# connections, etc.) -- see docs/TAKSERVER_CORECONFIG.md for the rationale.
preserve_federation_config() {
    local source_file="$1"
    local target_file="$2"

    if [[ -z "$source_file" ]]; then
        return 0
    fi

    local ns_federation="/*[local-name()='Configuration']/*[local-name()='federation']"
    if ! xmlstarlet sel -t -v "count($ns_federation)" "$source_file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
        echo "No <federation> element found in existing config, nothing to preserve"
        return 0
    fi

    echo "Preserving existing <federation> configuration from prior container run"

    python3 - "$source_file" "$target_file" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

source_file, target_file = sys.argv[1], sys.argv[2]
ns = "http://bbn.com/marti/xml/config"
tag = f"{{{ns}}}federation"

ET.register_namespace("", ns)

source_tree = ET.parse(source_file)
source_federation = source_tree.getroot().find(tag)
if source_federation is None:
    sys.exit(0)

target_tree = ET.parse(target_file)
target_root = target_tree.getroot()
target_federation = target_root.find(tag)

children = list(target_root)
if target_federation is not None:
    index = children.index(target_federation)
    target_root.remove(target_federation)
else:
    index = len(children)

target_root.insert(index, source_federation)
target_tree.write(target_file, xml_declaration=True, encoding="UTF-8")
PYEOF

    if [[ $? -ne 0 ]]; then
        echo "Warning: Failed to preserve existing <federation> configuration, using freshly generated federation config instead"
    fi
}

# Ensure a preserved <federation-server> still meets the current XSD's
# structural requirements. Only relevant when federation config was carried
# over from an older TAK Server version (see preserve_federation_config) --
# freshly generated federation content from the template is always valid.
fix_federation_server_structure() {
    local file="$1"

    if ! xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server'])" "$file" 2>/dev/null | grep -q "^[1-9][0-9]*$"; then
        return 0
    fi

    echo "Checking preserved federation-server element for XSD compliance"

    # Ensure federation-server has the required tls child element
    if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='tls'])" "$file" 2>/dev/null | grep -q "^0$"; then
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
            "$file" 2>/dev/null
    fi

    # Ensure federation-server has webBaseUrl attribute (optional but recommended)
    if ! xmlstarlet sel -t -v "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/@webBaseUrl" "$file" 2>/dev/null | grep -q "."; then
        echo "Adding webBaseUrl attribute to federation-server"
        xmlstarlet ed --inplace -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']" -t attr -n "webBaseUrl" -v "https://localhost:8443/Marti" "$file" 2>/dev/null
    fi

    # Ensure federation-server has at least one required child element after tls
    if xmlstarlet sel -t -v "count(/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='federation-port' or local-name()='v1Tls' or local-name()='federation-token-authentication'])" "$file" 2>/dev/null | grep -q "^0$"; then
        echo "Adding missing federation-port element to federation-server"
        xmlstarlet ed --inplace -s "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']" -t elem -n "federation-port" \
            -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='federation-port'][last()]" -t attr -n "port" -v "9000" \
            -i "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']/*[local-name()='federation-port'][last()]" -t attr -n "tlsVersion" -v "TLSv1.2" \
            "$file" 2>/dev/null
    fi
}

# Enable debug mode if requested
DEBUG=${DEBUG:-false}
if [[ "${DEBUG,,}" == "true" ]]; then
    set -x
    echo "Debug mode enabled"
fi

# Detect TAK Server version and select appropriate template
detect_tak_version() {
    local version="${TAK_VERSION#takserver-docker-}"
    local major_minor="${version%%-*}"

    if [[ "$major_minor" =~ ^5\.[0-4] ]]; then
        echo "5.4"
    elif [[ "$major_minor" == "5.5" ]]; then
        echo "5.5"
    elif [[ "$major_minor" =~ ^5\.[6-9] ]]; then
        echo "5.6"
    else
        echo "5.4"  # Default fallback
    fi
}

# Template substitution function
substitute_template() {
    local template_file="$1"
    local output_file="$2"

    # Read template and substitute variables
    sed -e "s|{{SERVER_ID}}|$SERVER_ID|g" \
        -e "s|{{TAK_VERSION}}|${TAK_VERSION#takserver-docker-}|g" \
        -e "s|{{CLOUDWATCH_ENABLE}}|$(get_env_value "TAKSERVER_CoreConfig_Network_CloudwatchEnable" "false" "boolean")|g" \
        -e "s|{{STACK_NAME}}|$StackName|g" \
        -e "s|{{INPUT_AUTH}}|$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Auth" "x509")|g" \
        -e "s|{{INPUT_ARCHIVE}}|$(get_env_value "TAKSERVER_CoreConfig_Network_Input_8089_Archive" "true" "boolean")|g" \
        -e "s|{{LETSENCRYPT_DOMAIN}}|$LETSENCRYPT_DOMAIN|g" \
        -e "s|{{AUTH_DEFAULT}}|$(get_env_value "TAKSERVER_CoreConfig_Auth_Default" "ldap")|g" \
        -e "s|{{X509_USE_GROUP_CACHE}}|$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCache" "false" "boolean")|g" \
        -e "s|{{X509_USE_GROUP_CACHE_DEFAULT_ACTIVE}}|$(get_env_value "TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive" "false" "boolean")|g" \
        -e "s|{{LDAP_URL}}|$LDAP_SECURE_URL|g" \
        -e "s|{{LDAP_USERSTRING}}|cn={username},ou=users,$LDAP_DN|g" \
        -e "s|{{LDAP_GROUP_PREFIX}}|$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix" "cn=tak_" | sed 's/[|&/\]/\\&/g')|g" \
        -e "s|{{LDAP_GROUP_REGEX}}|$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex" "cn=tak_(.*)" | sed 's/[|&/\]/\\&/g')|g" \
        -e "s|{{LDAP_SERVICE_DN}}|cn=ldapservice,ou=users,$LDAP_DN|g" \
        -e "s|{{LDAP_PASSWORD}}|$LDAP_Password|g" \
        -e "s|{{LDAP_GROUP_BASE}}|ou=groups,$LDAP_DN|g" \
        -e "s|{{LDAP_USER_BASE}}|ou=users,$LDAP_DN|g" \
        -e "s|{{DB_URL}}|$PostgresURL|g" \
        -e "s|{{DB_USERNAME}}|$PostgresUsername|g" \
        -e "s|{{DB_PASSWORD}}|$PostgresPassword|g" \
        -e "s|{{FEDERATION_ENABLED}}|$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableFederation" "true" "boolean")|g" \
        "$template_file" > "$output_file"
}

# Generate OAuth section
generate_oauth_section() {
    local oauth_server_name=$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Name" "")

    if [[ -n "$oauth_server_name" ]]; then
        local trust_all_certs=$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts" "false" "boolean")
        local trust_attr=""
        [[ "$trust_all_certs" == "true" ]] && trust_attr=' trustAllCerts="true"'

        cat << EOF
        <oauth usernameClaim="$(get_env_value "TAKSERVER_CoreConfig_OAuth_UsernameClaim" "preferred_username")">
            <authServer name="$oauth_server_name" issuer="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Issuer" "")" clientId="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_ClientId" "")" secret="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Secret" "")" redirectUri="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_RedirectUri" "")" scope="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_Scope" "")" authEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint" "")" tokenEndpoint="$(get_env_value "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint" "")"$trust_attr/>
        </oauth>
EOF
    fi
}

# Set commonly used values
TAK_VERSION_DETECTED=$(detect_tak_version)
LETSENCRYPT_DOMAIN=$(get_env_value "TAKSERVER_QuickConnect_LetsEncrypt_Domain" "nodomainset")
SERVER_ID=$(cat /proc/sys/kernel/random/uuid)

# Download and setup AWS Root CA
if curl -s --max-time 30 --fail https://www.amazontrust.com/repository/AmazonRootCA1.pem > /tmp/AmazonRootCA1.pem; then
    echo "yes" | keytool -import -file /tmp/AmazonRootCA1.pem -alias AWS -deststoretype JKS -deststorepass INTENTIONALLY_NOT_SENSITIVE -keystore /tmp/AmazonRootCA1.jks >/dev/null 2>&1
    cp /tmp/AmazonRootCA1.jks /opt/tak/certs/files/aws-acm-root.jks 2>/dev/null || true
else
    echo "Warning: Failed to download AWS Root CA, continuing without it"
fi

# Check for an existing file so we can preserve its <federation> config later
check_existing_file

# Print environment variables that will affect configuration (debug only)
if [[ "${DEBUG,,}" == "true" ]]; then
    echo "Environment variables affecting CoreConfig.xml:"
    env | grep -E "^TAKSERVER_CoreConfig_" | sort
    echo "Default values from project-defaults.env:"
    env | grep -E "^TAKSERVER_CoreConfig_.*_DEFAULT" | sort
fi

# Generate CoreConfig.xml using version-specific template
echo "Detected TAK Server version: $TAK_VERSION_DETECTED"
TEMPLATE_FILE="$SCRIPT_DIR/templates/coreconfig-$TAK_VERSION_DETECTED.xml"
FEDERATION_TEMPLATE="$SCRIPT_DIR/templates/federation-server-$TAK_VERSION_DETECTED.xml"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "Warning: Template for version $TAK_VERSION_DETECTED not found, using 5.4 template"
    TEMPLATE_FILE="$SCRIPT_DIR/templates/coreconfig-5.4.xml"
    FEDERATION_TEMPLATE="$SCRIPT_DIR/templates/federation-server-5.4.xml"
fi

# Generate OAuth and Federation sections
OAUTH_SECTION=$(generate_oauth_section)
FEDERATION_SERVER_SECTION=""
if [[ "$(get_env_value "TAKSERVER_CoreConfig_Federation_EnableFederation" "true" "boolean")" == "true" ]]; then
    if [[ -f "$FEDERATION_TEMPLATE" ]]; then
        FEDERATION_SERVER_SECTION=$(substitute_template "$FEDERATION_TEMPLATE" /dev/stdout)
    fi
fi

# Generate CoreConfig.xml from template into TEMP_FILE. This is always the
# starting point -- there is no merge-with-existing-file code path anymore.
substitute_template "$TEMPLATE_FILE" "$TEMP_FILE"

# Replace template placeholders for complex sections using temporary files
if [[ -n "$OAUTH_SECTION" ]]; then
    # Write OAuth section to temporary file and use it for replacement
    OAUTH_TEMP=$(mktemp)
    echo "$OAUTH_SECTION" > "$OAUTH_TEMP"
    # Use awk for multi-line replacement
    awk -v oauth_file="$OAUTH_TEMP" '
        /{{OAUTH_SECTION}}/ {
            while ((getline line < oauth_file) > 0) {
                print line
            }
            close(oauth_file)
            next
        }
        { print }
    ' "$TEMP_FILE" > "${TEMP_FILE}.tmp" && mv "${TEMP_FILE}.tmp" "$TEMP_FILE"
    rm -f "$OAUTH_TEMP"
else
    sed -i 's/{{OAUTH_SECTION}}//g' "$TEMP_FILE"
fi

if [[ -n "$FEDERATION_SERVER_SECTION" ]]; then
    # Write federation section to temporary file and use it for replacement
    FED_TEMP=$(mktemp)
    echo "$FEDERATION_SERVER_SECTION" > "$FED_TEMP"
    # Use awk for multi-line replacement
    awk -v fed_file="$FED_TEMP" '
        /{{FEDERATION_SERVER_SECTION}}/ {
            while ((getline line < fed_file) > 0) {
                print line
            }
            close(fed_file)
            next
        }
        { print }
    ' "$TEMP_FILE" > "${TEMP_FILE}.tmp" && mv "${TEMP_FILE}.tmp" "$TEMP_FILE"
    rm -f "$FED_TEMP"
else
    sed -i 's/{{FEDERATION_SERVER_SECTION}}//g' "$TEMP_FILE"
fi

# Work on a temporary file to avoid writing invalid config to disk
WORK_FILE=$(mktemp)
cp "$TEMP_FILE" "$WORK_FILE"

# Apply CDK/S3-driven settings that are not covered by template placeholders.
echo "Applying CDK environment variable overrides"

# Set takServerHost on the network element — required by createFileTransferRequest
# to build HTTPS URLs for Data Sync content download (e.g. mission file attachments)
letsencrypt_domain_for_host=$(get_env_value "TAKSERVER_QuickConnect_LetsEncrypt_Domain" "")
if [[ -n "$letsencrypt_domain_for_host" ]]; then
    safe_xml_update "/Configuration/network/@takServerHost" "$letsencrypt_domain_for_host" "$WORK_FILE"
fi

ldap_admin_group=$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_AdminGroup" "")
if [[ -n "$ldap_admin_group" ]]; then
    echo "Applying LDAP admin group: $ldap_admin_group"
    safe_xml_update "/Configuration/auth/ldap/@adminGroup" "$ldap_admin_group" "$WORK_FILE"
fi

ldap_enable_connection_pool=$(get_env_value "TAKSERVER_CoreConfig_Auth_LDAP_EnableConnectionPool" "")
if [[ -n "$ldap_enable_connection_pool" ]]; then
    echo "Applying LDAP connection pool: $ldap_enable_connection_pool"
    safe_xml_update "/Configuration/auth/ldap/@enableConnectionPool" "$ldap_enable_connection_pool" "$WORK_FILE"
fi

# Mission settings
mission_use_groups=$(get_env_value "TAKSERVER_CoreConfig_Network_MissionUseGroupsForContents" "")
if [[ -n "$mission_use_groups" ]]; then
    echo "Applying MissionUseGroupsForContents: $mission_use_groups"
    safe_xml_update "/Configuration/network/@MissionUseGroupsForContents" "$mission_use_groups" "$WORK_FILE"
fi

mission_strict_uid=$(get_env_value "TAKSERVER_CoreConfig_Network_MissionStrictUidMissionMembership" "")
if [[ -n "$mission_strict_uid" ]]; then
    echo "Applying MissionStrictUidMissionMembership: $mission_strict_uid"
    safe_xml_update "/Configuration/network/@MissionStrictUidMissionMembership" "$mission_strict_uid" "$WORK_FILE"
fi

always_archive_mission_cot=$(get_env_value "TAKSERVER_CoreConfig_Network_AlwaysArchiveMissionCot" "")
if [[ -n "$always_archive_mission_cot" ]]; then
    echo "Applying alwaysArchiveMissionCot: $always_archive_mission_cot"
    safe_xml_update "/Configuration/network/@alwaysArchiveMissionCot" "$always_archive_mission_cot" "$WORK_FILE"
fi

mission_create_groups_regex=$(get_env_value "TAKSERVER_CoreConfig_Network_MissionCreateGroupsRegex" "")
if [[ -n "$mission_create_groups_regex" ]]; then
    echo "Applying MissionCreateGroupsRegex: $mission_create_groups_regex"
    safe_xml_update "/Configuration/network/@MissionCreateGroupsRegex" "$mission_create_groups_regex" "$WORK_FILE"
fi

mission_delete_requires_owner=$(get_env_value "TAKSERVER_CoreConfig_Network_MissionDeleteRequiresOwner" "")
if [[ -n "$mission_delete_requires_owner" ]]; then
    echo "Applying MissionDeleteRequiresOwner: $mission_delete_requires_owner"
    safe_xml_update "/Configuration/network/@MissionDeleteRequiresOwner" "$mission_delete_requires_owner" "$WORK_FILE"
fi

mission_allow_group_change=$(get_env_value "TAKSERVER_CoreConfig_Network_MissionAllowGroupChange" "")
if [[ -n "$mission_allow_group_change" ]]; then
    echo "Applying MissionAllowGroupChange: $mission_allow_group_change"
    safe_xml_update "/Configuration/network/@MissionAllowGroupChange" "$mission_allow_group_change" "$WORK_FILE"
fi

mission_broker_uid_adds_from_api=$(get_env_value "TAKSERVER_CoreConfig_Network_MissionBrokerUidAddsFromApi" "")
if [[ -n "$mission_broker_uid_adds_from_api" ]]; then
    echo "Applying MissionBrokerUidAddsFromApi: $mission_broker_uid_adds_from_api"
    safe_xml_update "/Configuration/network/@MissionBrokerUidAddsFromApi" "$mission_broker_uid_adds_from_api" "$WORK_FILE"
fi

disable_broadcast_map_items=$(get_env_value "TAKSERVER_CoreConfig_Network_DisableBroadcastMapItems" "")
if [[ -n "$disable_broadcast_map_items" ]]; then
    echo "Applying disableBroadcastMapItems: $disable_broadcast_map_items"
    safe_xml_update "/Configuration/network/@disableBroadcastMapItems" "$disable_broadcast_map_items" "$WORK_FILE"
fi

# Let's Encrypt settings from CDK
letsencrypt_domain=$(get_env_value "TAKSERVER_QuickConnect_LetsEncrypt_Domain" "")
if [[ -n "$letsencrypt_domain" ]]; then
    safe_xml_update "/Configuration/network/connector[@port='8443']/@keystoreFile" "/opt/tak/certs/files/$letsencrypt_domain/letsencrypt.jks" "$WORK_FILE"
    safe_xml_update "/Configuration/network/connector[@port='8446']/@keystoreFile" "/opt/tak/certs/files/$letsencrypt_domain/letsencrypt.jks" "$WORK_FILE"
fi

# Remove legacy keystore attributes from port 8443 connector - the HTTPS connector
# does not use a JKS keystore; these attributes were incorrectly included in older templates
xmlstarlet ed --inplace \
    -d "/*[local-name()='Configuration']/*[local-name()='network']/*[local-name()='connector'][@port='8443']/@keystore" \
    -d "/*[local-name()='Configuration']/*[local-name()='network']/*[local-name()='connector'][@port='8443']/@keystoreFile" \
    -d "/*[local-name()='Configuration']/*[local-name()='network']/*[local-name()='connector'][@port='8443']/@keystorePass" \
    "$WORK_FILE" 2>/dev/null || true

# WebTAK connector settings from CDK
webtak_8443_enabled=$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak" "")
if [[ -n "$webtak_8443_enabled" ]]; then
    echo "Applying WebTAK enablement for port 8443: $webtak_8443_enabled"
    safe_xml_update "/Configuration/network/connector[@port='8443']/@enableWebtak" "$webtak_8443_enabled" "$WORK_FILE"
fi

webtak_8446_enabled=$(get_env_value "TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak" "")
if [[ -n "$webtak_8446_enabled" ]]; then
    echo "Applying WebTAK enablement for port 8446: $webtak_8446_enabled"
    safe_xml_update "/Configuration/network/connector[@port='8446']/@enableWebtak" "$webtak_8446_enabled" "$WORK_FILE"
fi

# Create optional elements (locate, vbm, plugins, cluster, docs, logging) if
# their trigger environment variables are set
create_missing_elements "$WORK_FILE"

# Fix locate element attributes from environment variables (in case it
# already existed with different values, e.g. from create_missing_elements
# not needing to create it)
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

# Preserve the existing <federation> element, if any, before final validation.
# This must run after all other settings are applied so the preserved
# federation content is never touched by anything above.
preserve_federation_config "$EXISTING_FILE" "$WORK_FILE"
fix_federation_server_structure "$WORK_FILE"

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
