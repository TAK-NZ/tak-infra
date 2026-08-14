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
    
    # The vendor's internal zip folder name doesn't always match the zip filename/version
    # exactly (e.g. "takserver-docker-hardened-<version>" vs "takserver-docker-<version>"),
    # so match by wildcard instead of reconstructing the exact path.
    
    # Extract XSD file
    if unzip -o -j "$zip_file" "*/tak/CoreConfig.xsd" -d "$SCRIPT_DIR" 2>/dev/null; then
        echo "Updated CoreConfig.xsd"
    else
        echo "Warning: Could not extract CoreConfig.xsd from zip"
    fi
    
    # Extract validation script
    if unzip -o -j "$zip_file" "*/tak/validateConfig.sh" -d "$SCRIPT_DIR" 2>/dev/null; then
        chmod +x "$SCRIPT_DIR/validateConfig.sh"
        echo "Updated validateConfig.sh"
    else
        echo "Warning: Could not extract validateConfig.sh from zip"
    fi
}

# Update test files before running tests
update_test_files

# Validate OAuth TrustAllCerts attribute
validate_oauth_trustallcerts() {
    local xml_file="$1"
    
    # Check if TrustAllCerts environment variable is set to true
    if [[ "${TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts,,}" == "true" ]]; then
        # Verify the attribute exists in the XML
        if ! grep -q 'trustAllCerts="true"' "$xml_file"; then
            echo "Missing trustAllCerts='true' attribute in OAuth authServer element"
            return 1
        fi
    fi
    
    return 0
}

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
    
    # Only check for federation-server if federation is enabled
    if [[ "${TAKSERVER_CoreConfig_Federation_EnableFederation,,}" != "false" ]]; then
        if ! grep -q "<federation-server" "$xml_file"; then
            missing_sections+=("federation/federation-server")
        fi
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
    # Extract TAK version from cdk.json
    local tak_version=$(grep -o '"version": "[^"]*"' "$SCRIPT_DIR/../../cdk.json" | head -1 | cut -d'"' -f4)
    export TAK_VERSION="takserver-docker-${tak_version:-5.4-RELEASE-19}"
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
        if validate_mandatory_sections "$TEST_DIR/CoreConfig.xml" && validate_oauth_trustallcerts "$TEST_DIR/CoreConfig.xml"; then
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
    unset TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts
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

# Test 10: OAuth with TrustAllCerts
run_test "OAuth with TrustAllCerts" \
    "TAKSERVER_CoreConfig_OAuthServer_Name=TrustAllTest" \
    "TAKSERVER_CoreConfig_OAuthServer_Issuer=https://oauth.example.com" \
    "TAKSERVER_CoreConfig_OAuthServer_ClientId=trust-client" \
    "TAKSERVER_CoreConfig_OAuthServer_Secret=trust-secret" \
    "TAKSERVER_CoreConfig_OAuthServer_RedirectUri=https://tak.example.com/oauth" \
    "TAKSERVER_CoreConfig_OAuthServer_Scope=openid" \
    "TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint=https://oauth.example.com/auth" \
    "TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint=https://oauth.example.com/token" \
    "TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts=true"

# Test 11: LDAP groupprefix, groupNameExtractorRegex, and the new user/group
# object class + connection pool timeout attributes
run_test "LDAP Group Attributes" \
    "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix=cn=tak_" \
    "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex=cn=tak_(.*?)(?:,|\$)" \
    "TAKSERVER_CoreConfig_Auth_LDAP_UserObjectClass=inetOrgPerson" \
    "TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass=groupOfNames" \
    "TAKSERVER_CoreConfig_Auth_LDAP_EnableConnectionPool=false" \
    "TAKSERVER_CoreConfig_Auth_LDAP_ConnectionPoolTimeout=30000" \
    "TAKSERVER_CoreConfig_Auth_LDAP_UserBaseRDN=ou=users" \
    "TAKSERVER_CoreConfig_Auth_LDAP_GroupBaseRDN=ou=groups"

# Test 11: Empty optional values
run_test "Empty Optional Values" \
    "TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix=" \
    "TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex="

# Test 12: Dynamic attribute support
run_test "Dynamic Attribute Support" \
    "TAKSERVER_CoreConfig_Security_TLS_Context=TLSv1.2" \
    "TAKSERVER_CoreConfig_Federation_Server_TLS_Context=TLSv1.3"

# Test 13: Submission/Subscription attributes
run_test "Submission/Subscription Attributes" \
    "TAKSERVER_CoreConfig_Submission_IgnoreStaleMessages=true" \
    "TAKSERVER_CoreConfig_Submission_ValidateXml=true" \
    "TAKSERVER_CoreConfig_Subscription_ReloadPersistent=true"

# Test 14: OIDC Discovery Trust only (e.g. CloudTAK trust with no WebTAK OAuth)
run_test "OIDC Discovery Trust Only" \
    "TAKSERVER_CoreConfig_OIDCDiscovery_Name=CloudTAK" \
    "TAKSERVER_CoreConfig_OIDCDiscovery_ClientId=discovery-client" \
    "TAKSERVER_CoreConfig_OIDCDiscovery_Secret=discovery-secret" \
    "TAKSERVER_CoreConfig_OIDCDiscovery_RedirectUri=https://map.example.com/login/redirect" \
    "TAKSERVER_CoreConfig_OIDCDiscovery_ConfigurationUri=https://account.example.com/application/o/cloudtak/.well-known/openid-configuration"

# Test 15: OAuthServer + OIDC Discovery Trust combined (WebTAK OAuth plus a
# second, discovery-based provider trust, e.g. CloudTAK). Verifies both
# <authServer> and <openIdDiscoveryConfiguration> are present, in the
# schema-required order (authServer first).
test_oauth_and_oidc_discovery_combined() {
    local test_name="OAuthServer and OIDC Discovery Trust Combined"
    TEST_COUNT=$((TEST_COUNT + 1))

    echo "=== Test $TEST_COUNT: $test_name ==="

    export PostgresUsername="testuser"
    export PostgresPassword="testpass"
    export PostgresURL="postgresql://localhost:5432/testdb"
    local tak_version=$(grep -o '"version": "[^"]*"' "$SCRIPT_DIR/../../cdk.json" | head -1 | cut -d'"' -f4)
    export TAK_VERSION="takserver-docker-${tak_version:-5.4-RELEASE-19}"
    export LDAP_DN="dc=example,dc=com"
    export LDAP_SECURE_URL="ldaps://ldap.example.com:636"
    export LDAP_Password="ldappass"
    export StackName="TestStack"
    export TAKSERVER_CoreConfig_OAuthServer_Name="WebTAK Account"
    export TAKSERVER_CoreConfig_OAuthServer_Issuer="/opt/tak/certs/files/oauth-public-key.pem"
    export TAKSERVER_CoreConfig_OAuthServer_ClientId="webtak-client"
    export TAKSERVER_CoreConfig_OAuthServer_Secret="webtak-secret"
    export TAKSERVER_CoreConfig_OAuthServer_RedirectUri="https://ops.example.com/login/redirect"
    export TAKSERVER_CoreConfig_OAuthServer_Scope="openid profile"
    export TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint="https://account.example.com/application/o/authorize/"
    export TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint="https://account.example.com/application/o/token/"
    export TAKSERVER_CoreConfig_OIDCDiscovery_Name="CloudTAK"
    export TAKSERVER_CoreConfig_OIDCDiscovery_ClientId="cloudtak-client"
    export TAKSERVER_CoreConfig_OIDCDiscovery_Secret="cloudtak-secret"
    export TAKSERVER_CoreConfig_OIDCDiscovery_RedirectUri="https://map.example.com/login/redirect"
    export TAKSERVER_CoreConfig_OIDCDiscovery_ConfigurationUri="https://account.example.com/application/o/cloudtak/.well-known/openid-configuration"

    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    mkdir -p tmp/test-tak/certs/files

    if ! bash "$SCRIPT_DIR/$CREATE_SCRIPT" "$TEST_DIR/CoreConfig.xml" > test_output.log 2>&1; then
        echo "❌ FAIL: $test_name - Script execution failed"
        cat test_output.log
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        # Both elements must be present, and authServer must appear before
        # openIdDiscoveryConfiguration per CoreConfig.xsd's sequence order.
        local auth_line=$(grep -n '<authServer ' "$TEST_DIR/CoreConfig.xml" | head -1 | cut -d: -f1)
        local discovery_line=$(grep -n '<openIdDiscoveryConfiguration ' "$TEST_DIR/CoreConfig.xml" | head -1 | cut -d: -f1)

        if [[ -z "$auth_line" || -z "$discovery_line" ]]; then
            echo "❌ FAIL: $test_name - missing authServer or openIdDiscoveryConfiguration element"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [[ "$auth_line" -ge "$discovery_line" ]]; then
            echo "❌ FAIL: $test_name - authServer must precede openIdDiscoveryConfiguration per XSD sequence"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif cd "$SCRIPT_DIR" && ./validateConfig.sh "$TEST_DIR/CoreConfig.xml" > "$TEST_DIR/validation.log" 2>&1; then
            echo "✅ PASS: $test_name"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "❌ FAIL: $test_name - XML validation failed"
            cat "$TEST_DIR/validation.log"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi

    rm -rf "$TEST_DIR"
    unset TAKSERVER_CoreConfig_OAuthServer_Name TAKSERVER_CoreConfig_OAuthServer_Issuer \
          TAKSERVER_CoreConfig_OAuthServer_ClientId TAKSERVER_CoreConfig_OAuthServer_Secret \
          TAKSERVER_CoreConfig_OAuthServer_RedirectUri TAKSERVER_CoreConfig_OAuthServer_Scope \
          TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint \
          TAKSERVER_CoreConfig_OIDCDiscovery_Name TAKSERVER_CoreConfig_OIDCDiscovery_ClientId \
          TAKSERVER_CoreConfig_OIDCDiscovery_Secret TAKSERVER_CoreConfig_OIDCDiscovery_RedirectUri \
          TAKSERVER_CoreConfig_OIDCDiscovery_ConfigurationUri
    echo ""
}

test_oauth_and_oidc_discovery_combined

# Test: 8089 input authRequired defaults to true (secure-by-default), and can
# be explicitly overridden to false.
#
# The CoreConfig XSD itself defaults authRequired to "false" (accept and
# archive unauthenticated connections with no identity/groups). We
# deliberately override that default to "true" in createCoreConfig.sh, so
# this test asserts both that the override is in effect when unset, and that
# an explicit env var still controls it.
test_input_8089_auth_required() {
    local test_name="Input 8089 AuthRequired defaults to true and is overridable"
    TEST_COUNT=$((TEST_COUNT + 1))

    echo "=== Test $TEST_COUNT: $test_name ==="

    export PostgresUsername="testuser"
    export PostgresPassword="testpass"
    export PostgresURL="postgresql://localhost:5432/testdb"
    local tak_version=$(grep -o '"version": "[^"]*"' "$SCRIPT_DIR/../../cdk.json" | head -1 | cut -d'"' -f4)
    export TAK_VERSION="takserver-docker-${tak_version:-5.4-RELEASE-19}"
    export LDAP_DN="dc=example,dc=com"
    export LDAP_SECURE_URL="ldaps://ldap.example.com:636"
    export LDAP_Password="ldappass"
    export StackName="TestStack"

    local overall_pass=true

    # Case 1: unset -> should default to authRequired="true"
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    mkdir -p tmp/test-tak/certs/files
    if ! bash "$SCRIPT_DIR/$CREATE_SCRIPT" "$TEST_DIR/CoreConfig.xml" > test_output.log 2>&1; then
        echo "❌ FAIL: $test_name - script execution failed (default case)"
        cat test_output.log
        overall_pass=false
    elif ! grep -q '<input[^>]*authRequired="true"' "$TEST_DIR/CoreConfig.xml"; then
        echo "❌ FAIL: $test_name - default authRequired was not \"true\""
        grep '<input' "$TEST_DIR/CoreConfig.xml" || true
        overall_pass=false
    elif ! (cd "$SCRIPT_DIR" && ./validateConfig.sh "$TEST_DIR/CoreConfig.xml" > "$TEST_DIR/validation.log" 2>&1); then
        echo "❌ FAIL: $test_name - default case XML validation failed"
        cat "$TEST_DIR/validation.log"
        overall_pass=false
    fi
    rm -rf "$TEST_DIR"

    # Case 2: explicitly set to false -> should be overridable
    export TAKSERVER_CoreConfig_Network_Input_8089_AuthRequired=false
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    mkdir -p tmp/test-tak/certs/files
    if ! bash "$SCRIPT_DIR/$CREATE_SCRIPT" "$TEST_DIR/CoreConfig.xml" > test_output.log 2>&1; then
        echo "❌ FAIL: $test_name - script execution failed (override case)"
        cat test_output.log
        overall_pass=false
    elif ! grep -q '<input[^>]*authRequired="false"' "$TEST_DIR/CoreConfig.xml"; then
        echo "❌ FAIL: $test_name - explicit authRequired=false override did not apply"
        grep '<input' "$TEST_DIR/CoreConfig.xml" || true
        overall_pass=false
    elif ! (cd "$SCRIPT_DIR" && ./validateConfig.sh "$TEST_DIR/CoreConfig.xml" > "$TEST_DIR/validation.log" 2>&1); then
        echo "❌ FAIL: $test_name - override case XML validation failed"
        cat "$TEST_DIR/validation.log"
        overall_pass=false
    fi
    rm -rf "$TEST_DIR"
    unset TAKSERVER_CoreConfig_Network_Input_8089_AuthRequired

    if [[ "$overall_pass" == "true" ]]; then
        echo "✅ PASS: $test_name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    echo ""
}

test_input_8089_auth_required

# Test 14: Federation configuration is preserved across regeneration
#
# CoreConfig.xml is otherwise fully regenerated from the template + S3/CDK
# environment variables on every container start. <federation> is the one
# exception: TAK Server itself writes admin-configured federation state
# (e.g. outgoing connections added via the Marti admin UI) back into
# CoreConfig.xml at runtime, so it must survive a regeneration or that
# state would be silently lost on the next container restart.
#
# This test simulates that runtime write by injecting a fake
# <federation-outgoing> element (the actual element TAK Server writes when
# an admin adds an outgoing federation connection) into a first-generated
# CoreConfig.xml, then re-running the generator against the same output
# path and asserting the injected element survived unchanged.
test_federation_preservation() {
    local test_name="Federation Configuration Preserved Across Regeneration"
    TEST_COUNT=$((TEST_COUNT + 1))

    echo "=== Test $TEST_COUNT: $test_name ==="

    export PostgresUsername="testuser"
    export PostgresPassword="testpass"
    export PostgresURL="postgresql://localhost:5432/testdb"
    local tak_version=$(grep -o '"version": "[^"]*"' "$SCRIPT_DIR/../../cdk.json" | head -1 | cut -d'"' -f4)
    export TAK_VERSION="takserver-docker-${tak_version:-5.4-RELEASE-19}"
    export LDAP_DN="dc=example,dc=com"
    export LDAP_SECURE_URL="ldaps://ldap.example.com:636"
    export LDAP_Password="ldappass"
    export StackName="TestStack"
    export TAKSERVER_CoreConfig_Federation_EnableFederation="true"

    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    mkdir -p tmp/test-tak/certs/files

    # First run: generate a baseline CoreConfig.xml
    if ! bash "$SCRIPT_DIR/$CREATE_SCRIPT" "$TEST_DIR/CoreConfig.xml" > first_run.log 2>&1; then
        echo "❌ FAIL: $test_name - first script run failed"
        cat first_run.log
        FAIL_COUNT=$((FAIL_COUNT + 1))
        rm -rf "$TEST_DIR"
        unset TAKSERVER_CoreConfig_Federation_EnableFederation
        echo ""
        return
    fi

    # Simulate TAK Server's runtime writeback: inject a fake outgoing
    # federation connection as a sibling of federation-server (this is where
    # TAK Server actually writes it, per the XSD and observed live behavior),
    # exactly as setAndSaveFederation() does when an admin adds one via the
    # admin UI.
    if ! xmlstarlet ed --inplace \
            -a "/*[local-name()='Configuration']/*[local-name()='federation']/*[local-name()='federation-server']" \
            -t elem -n "federation-outgoing" \
            -i "//*[local-name()='federation-outgoing'][last()]" -t attr -n "displayName" -v "TestFederate" \
            -i "//*[local-name()='federation-outgoing'][last()]" -t attr -n "address" -v "198.51.100.1" \
            -i "//*[local-name()='federation-outgoing'][last()]" -t attr -n "port" -v "9000" \
            -i "//*[local-name()='federation-outgoing'][last()]" -t attr -n "enabled" -v "true" \
            "$TEST_DIR/CoreConfig.xml" 2>inject.log; then
        echo "❌ FAIL: $test_name - could not inject test federation-outgoing element"
        cat inject.log
        FAIL_COUNT=$((FAIL_COUNT + 1))
        rm -rf "$TEST_DIR"
        unset TAKSERVER_CoreConfig_Federation_EnableFederation
        echo ""
        return
    fi

    # Second run: regenerate against the same output path
    if ! bash "$SCRIPT_DIR/$CREATE_SCRIPT" "$TEST_DIR/CoreConfig.xml" > second_run.log 2>&1; then
        echo "❌ FAIL: $test_name - second script run failed"
        cat second_run.log
        FAIL_COUNT=$((FAIL_COUNT + 1))
        rm -rf "$TEST_DIR"
        unset TAKSERVER_CoreConfig_Federation_EnableFederation
        echo ""
        return
    fi

    # Assert the injected federation-outgoing element survived the regeneration
    if grep -q 'federation-outgoing.*displayName="TestFederate"' "$TEST_DIR/CoreConfig.xml"; then
        # Also make sure the regenerated file is still XSD-valid
        if cd "$SCRIPT_DIR" && ./validateConfig.sh "$TEST_DIR/CoreConfig.xml" > "$TEST_DIR/validation.log" 2>&1; then
            echo "✅ PASS: $test_name"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "❌ FAIL: $test_name - regenerated file with preserved federation failed XML validation"
            cat "$TEST_DIR/validation.log"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "❌ FAIL: $test_name - injected federation-outgoing element was lost on regeneration"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    rm -rf "$TEST_DIR"
    unset TAKSERVER_CoreConfig_Federation_EnableFederation
    echo ""
}

test_federation_preservation

echo "========================================"
echo "Test Results:"
echo "Total Tests: $TEST_COUNT"
echo "Passed: $PASS_COUNT"
echo "Failed: $((TEST_COUNT - PASS_COUNT))"
echo "========================================"

if [ $PASS_COUNT -eq $TEST_COUNT ]; then
    echo "🎉 All tests passed!"
    exit 0
else
    echo "❌ Some tests failed"
    exit 1
fi