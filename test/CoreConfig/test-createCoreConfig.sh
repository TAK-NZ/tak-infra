#!/bin/bash

# Test script for createCoreConfig.sh
# Tests various permutations of inputs and validates XML output

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_SCRIPT="../../docker-container/scripts/createCoreConfig.sh"
VALIDATE_SCRIPT="./validateConfig.sh"
XSD_FILE="./CoreConfig.xsd"

# Update test files from TAK server zip if available
update_test_files() {
    local root_dir="$SCRIPT_DIR/../.."
    local cdk_json="$root_dir/cdk.json"
    
    # Extract TAK version from cdk.json
    local tak_version=$(grep -o '"version": "[^"]*"' "$cdk_json" | head -1 | cut -d'"' -f4)
    if [[ -z "$tak_version" ]]; then
        echo "Warning: Could not extract TAK version from cdk.json"
        return 0
    fi
    
    local zip_file="$root_dir/takserver-docker-$tak_version.zip"
    if [[ ! -f "$zip_file" ]]; then
        echo "Info: TAK server zip file not found: $zip_file"
        return 0
    fi
    
    echo "Updating test files from $zip_file..."
    
    # Extract XSD file
    if unzip -o -j "$zip_file" "takserver-docker-$tak_version/tak/CoreConfig.xsd" -d "$SCRIPT_DIR" 2>/dev/null; then
        echo "Updated CoreConfig.xsd"
    else
        echo "Warning: Could not extract CoreConfig.xsd from zip"
    fi
    
    # Extract validation script
    if unzip -o -j "$zip_file" "takserver-docker-$tak_version/tak/validateConfig.sh" -d "$SCRIPT_DIR" 2>/dev/null; then
        chmod +x "$SCRIPT_DIR/validateConfig.sh"
        echo "Updated validateConfig.sh"
    else
        echo "Warning: Could not extract validateConfig.sh from zip"
    fi
}

# Update test files before running tests
update_test_files

# Validate mandatory sections function
validate_mandatory_sections() {
    local xml_file="$1"
    local missing_sections=()
    
    # Check for mandatory sections based on backup/docker-container/scripts/CoreConfig.ts
    local mandatory_sections=(
        "network"
        "auth"
        "submission"
        "subscription" 
        "repository"
        "repeater"
        "filter"
        "buffer"
        "dissemination"
        "certificateSigning"
        "security"
        "federation"
        "plugins"
        "cluster"
        "vbm"
    )
    
    for section in "${mandatory_sections[@]}"; do
        if ! grep -q "<$section" "$xml_file"; then
            missing_sections+=("$section")
        fi
    done
    
    # Check for mandatory child elements
    if ! grep -q "<input" "$xml_file"; then
        missing_sections+=("network/input")
    fi
    
    if ! grep -q "<connector" "$xml_file"; then
        missing_sections+=("network/connector")
    fi
    
    if ! grep -q "<ldap" "$xml_file"; then
        missing_sections+=("auth/ldap")
    fi
    
    if ! grep -q "<connection" "$xml_file"; then
        missing_sections+=("repository/connection")
    fi
    
    if ! grep -q "<tls" "$xml_file"; then
        missing_sections+=("security/tls")
    fi
    
    if ! grep -q "<federation-server" "$xml_file"; then
        missing_sections+=("federation/federation-server")
    fi
    
    if ! grep -q "<TAKServerCAConfig" "$xml_file"; then
        missing_sections+=("certificateSigning/TAKServerCAConfig")
    fi
    
    if ! grep -q "<certificateConfig" "$xml_file"; then
        missing_sections+=("certificateSigning/certificateConfig")
    fi
    
    if [ ${#missing_sections[@]} -gt 0 ]; then
        echo "Missing mandatory sections: ${missing_sections[*]}"
        return 1
    fi
    
    return 0
}

# Test counter
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Test function
run_test() {
    local test_name="$1"
    shift
    TEST_COUNT=$((TEST_COUNT + 1))
    
    echo "=== Test $TEST_COUNT: $test_name ==="
    
    # Set up test environment
    export PostgresUsername="testuser"
    export PostgresPassword="testpass"
    export PostgresURL="postgresql://localhost:5432/testdb"
    export TAK_VERSION="5.4-RELEASE-19"
    export LDAP_DN="dc=example,dc=com"
    export LDAP_SECURE_URL="ldaps://ldap.example.com:636"
    export LDAP_Password="ldappass"
    export StackName="TestStack"
    
    # Set test-specific variables
    while [[ $# -gt 0 ]]; do
        export "$1"
        shift
    done
    
    # Create temp directory for test
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    
    # Create required directories in temp space
    mkdir -p tmp/test-tak/certs/files
    
    # Run the script with custom output path
    if bash "$SCRIPT_DIR/$CREATE_SCRIPT" "$TEST_DIR/CoreConfig.xml" > test_output.log 2>&1; then
        # Check for mandatory sections first
        if validate_mandatory_sections "$TEST_DIR/CoreConfig.xml"; then
            # Validate the generated XML
            if cd "$SCRIPT_DIR" && ./validateConfig.sh "$TEST_DIR/CoreConfig.xml" > "$TEST_DIR/validation.log" 2>&1; then
                echo "✅ PASS: $test_name"
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                echo "❌ FAIL: $test_name - XML validation failed"
                echo "Validation output:"
                cat "$TEST_DIR/validation.log"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            echo "❌ FAIL: $test_name - Missing mandatory sections"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "❌ FAIL: $test_name - Script execution failed"
        echo "Script output:"
        cat "$TEST_DIR/test_output.log"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    
    # Cleanup
    rm -rf "$TEST_DIR"
    
    # Unset test variables
    unset TAKSERVER_QuickConnect_LetsEncrypt_Domain
    unset TAKSERVER_CoreConfig_OAuthServer_Name
    unset TAKSERVER_CoreConfig_Federation_EnableFederation
    unset TAKSERVER_CoreConfig_Auth_LDAP_Userstring
    unset TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI
    
    echo ""
}

echo "Starting CoreConfig.sh validation tests..."
echo "========================================"

# Test 1: Basic configuration (minimal required fields)
run_test "Basic Configuration"

# Test 2: With custom Let's Encrypt domain
run_test "Custom Let's Encrypt Domain" \
    "TAKSERVER_QuickConnect_LetsEncrypt_Domain=test.example.com"

# Test 3: With OAuth enabled
run_test "OAuth Configuration" \
    "TAKSERVER_CoreConfig_OAuthServer_Name=TestOAuth" \
    "TAKSERVER_CoreConfig_OAuthServer_Issuer=https://oauth.example.com" \
    "TAKSERVER_CoreConfig_OAuthServer_ClientId=test-client" \
    "TAKSERVER_CoreConfig_OAuthServer_Secret=test-secret" \
    "TAKSERVER_CoreConfig_OAuthServer_RedirectUri=https://tak.example.com/oauth" \
    "TAKSERVER_CoreConfig_OAuthServer_Scope=openid profile" \
    "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint=https://oauth.example.com/auth" \
    "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint=https://oauth.example.com/token" \
    "TAKSERVER_CoreConfig_OAuthServer_AccessTokenName=access_token" \
    "TAKSERVER_CoreConfig_OAuthServer_RefreshTokenName=refresh_token"

# Test 4: With Federation enabled
run_test "Federation Configuration" \
    "TAKSERVER_CoreConfig_Federation_EnableFederation=true" \
    "TAKSERVER_CoreConfig_Federation_WebBaseUrl=https://tak.example.com:8443/Marti"

# Test 5: With Federation disabled
run_test "Federation Disabled" \
    "TAKSERVER_CoreConfig_Federation_EnableFederation=false"

# Test 6: Custom LDAP settings
run_test "Custom LDAP Configuration" \
    "TAKSERVER_CoreConfig_Auth_LDAP_Userstring=uid={username},ou=people," \
    "TAKSERVER_CoreConfig_Auth_LDAP_Style=AD" \
    "TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass=groupOfNames"

# Test 7: Custom connector settings
run_test "Custom Connector Configuration" \
    "TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI=false" \
    "TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak=false"

# Test 8: OAuth + Federation combined
run_test "OAuth and Federation Combined" \
    "TAKSERVER_CoreConfig_OAuthServer_Name=CombinedTest" \
    "TAKSERVER_CoreConfig_OAuthServer_Issuer=https://oauth.example.com" \
    "TAKSERVER_CoreConfig_OAuthServer_ClientId=combined-client" \
    "TAKSERVER_CoreConfig_OAuthServer_Secret=combined-secret" \
    "TAKSERVER_CoreConfig_OAuthServer_RedirectUri=https://tak.example.com/oauth" \
    "TAKSERVER_CoreConfig_OAuthServer_Scope=openid" \
    "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint=https://oauth.example.com/auth" \
    "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint=https://oauth.example.com/token" \
    "TAKSERVER_CoreConfig_OAuthServer_AccessTokenName=access_token" \
    "TAKSERVER_CoreConfig_OAuthServer_RefreshTokenName=refresh_token" \
    "TAKSERVER_CoreConfig_Federation_EnableFederation=true"

# Test 9: Boolean value variations (test case sensitivity)
run_test "Boolean Variations" \
    "TAKSERVER_CoreConfig_Auth_X509groups=TRUE" \
    "TAKSERVER_CoreConfig_Auth_X509addAnonymous=False" \
    "TAKSERVER_CoreConfig_Federation_EnableFederation=True"

# Test 10: LDAP groupprefix and groupNameExtractorRegex attributes
run_test "LDAP Group Attributes" \
    "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix=cn=tak_" \
    "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex=cn=(?:tak_)(.*?)(?:,|$)"

# Test 11: Empty optional values
run_test "Empty Optional Values" \
    "TAKSERVER_CoreConfig_OAuth_GroupsClaim=" \
    "TAKSERVER_QuickConnect_LetsEncrypt_Domain=nodomainset"

# Test 12: Dynamic attribute support (previously unsupported attributes)
run_test "Dynamic Attribute Support" \
    "TAKSERVER_CoreConfig_Network_Connector_8443_AllowOrigins=https://test.com,https://admin.com" \
    "TAKSERVER_CoreConfig_Network_AllowAllOrigins=true" \
    "TAKSERVER_CoreConfig_Repository_Archive=true"

# Test 13: Submission and Subscription explicit attributes
run_test "Submission/Subscription Attributes" \
    "TAKSERVER_CoreConfig_Submission_IgnoreStaleMessages=true" \
    "TAKSERVER_CoreConfig_Submission_ValidateXml=true" \
    "TAKSERVER_CoreConfig_Subscription_ReloadPersistent=true"

echo "========================================"
echo "Test Results:"
echo "Total Tests: $TEST_COUNT"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo "========================================"

if [ $FAIL_COUNT -eq 0 ]; then
    echo "🎉 All tests passed!"
    exit 0
else
    echo "💥 Some tests failed!"
    exit 1
fi