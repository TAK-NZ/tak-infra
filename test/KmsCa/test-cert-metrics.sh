#!/bin/bash
# Tests for docker-container/scripts/cert-metrics.sh (#129).
# A stub `aws` records every call, so no AWS credentials are needed. Needs: openssl, jq.
# Run from the repository root:  test/KmsCa/test-cert-metrics.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/docker-container/scripts/cert-metrics.sh"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete 2> /dev/null' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "expected to contain '$3', got '$2'"; }

command -v openssl > /dev/null || { echo "missing tool: openssl"; exit 1; }

# --- stub aws: one line per call: the arguments after "cloudwatch put-metric-data" ---------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/aws" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "cloudwatch put-metric-data" ]] || { echo "stub aws: unexpected: $*" >&2; exit 90; }
[[ -n "${STUB_AWS_FAILS:-}" ]] && { echo "Could not connect" >&2; exit 255; }
shift 2
echo "$*" >> "${STUB_AWS_LOG}"
EOF
chmod +x "${WORK}/bin/aws"
export PATH="${WORK}/bin:${PATH}" STUB_AWS_LOG="${WORK}/calls.log" StackName="TAK-Try-TakInfra"
calls() { [[ -f "${STUB_AWS_LOG}" ]] && cat "${STUB_AWS_LOG}" || true; }
reset() { rm -f "${STUB_AWS_LOG}"; }
ncalls() { calls | grep -c . ; }

# --- emit ---------------------------------------------------------------------------------
echo "emit"
reset
"${SCRIPT}" emit TakServerCertRotated > "${WORK}/out.log" 2>&1; rc=$?
assert_eq "a known metric is emitted" "${rc}" "0"
assert_eq "namespace, name, default value 1, unit, Stack dimension" "$(calls)" "--namespace TAK/Certificates --metric-name TakServerCertRotated --value 1 --unit Count --dimensions Stack=TAK-Try-TakInfra"
reset; "${SCRIPT}" emit RootCAExpiryWarning 0 > /dev/null 2>&1
assert_contains "an explicit value is used" "$(calls)" "--value 0 "
reset; "${SCRIPT}" emit IntermediateCARotationPhase 1 Phase=bridge > /dev/null 2>&1
assert_contains "an extra dimension is added after Stack" "$(calls)" "--dimensions Stack=TAK-Try-TakInfra,Phase=bridge"
reset; "${SCRIPT}" emit RotationCoverageStragglers 3.5 > /dev/null 2>&1
assert_contains "a decimal value is accepted" "$(calls)" "--value 3.5 "

echo "refused input (exit 2, nothing sent)"
for bad in "emit" "emit NotAMetric" "emit CAExpired abc" "emit CAExpired 1 Phase=a,Stack=other" "emit CAExpired 1 Phase" "emit CAExpired 1 =x" "emit CAExpired -1" "nonsense"; do
  reset; "${SCRIPT}" ${bad} > "${WORK}/out.log" 2>&1; rc=$?
  assert_eq "'${bad}' exits 2" "${rc}" "2"
  assert_eq "'${bad}' sends nothing" "$(ncalls)" "0"
done
reset; "${SCRIPT}" emit 'CAExpired; id' > /dev/null 2>&1; assert_eq "an injected metric name is refused" "$(ncalls)" "0"

echo "CloudWatch not reachable"
reset; STUB_AWS_FAILS=1 "${SCRIPT}" emit CAExpired > "${WORK}/out.log" 2>&1; rc=$?
assert_eq "emitting does not fail the caller" "${rc}" "0"
assert_contains "it says it continued" "$(cat "${WORK}/out.log")" "could not emit CAExpired"

echo "sourcing"
( CERT_METRICS_SOURCE_ONLY=1 source "${SCRIPT}"; reset; emit_metric CertbotRenewalFailure 1; [[ "$(ncalls)" == 1 ]] ) && pass "emit_metric works when sourced" || fail "emit_metric works when sourced"
( StackName= CERT_METRICS_SOURCE_ONLY=1 source "${SCRIPT}"; unset StackName; reset; emit_metric CAExpired 0; calls | grep -q "Stack=unknown" ) && pass "without StackName the dimension is Stack=unknown" || fail "without StackName the dimension is Stack=unknown"

# --- check-expiry ----------------------------------------------------------------------------
echo "check-expiry"
FILES="${WORK}/files"; mkdir -p "${FILES}"
export PKI_FILES_DIR="${FILES}"
mkcert() { # file days
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/k.pem" -subj "/CN=t" -days "$2" -out "${FILES}/$1" > /dev/null 2>&1
}
reset; "${SCRIPT}" check-expiry > "${WORK}/out.log" 2>&1; rc=$?
assert_eq "a stack without pki-state.json is skipped" "${rc}" "0"
assert_eq "and emits nothing" "$(ncalls)" "0"

echo '{}' > "${FILES}/pki-state.json"
mkcert root-ca.pem 7300; mkcert intermediate-ca.pem 3650; mkcert enrollment-ca.pem 1095
reset; "${SCRIPT}" check-expiry > "${WORK}/out.log" 2>&1
assert_eq "three metrics are emitted every time" "$(ncalls)" "3"
assert_contains "RootCAExpiryWarning is 0 for a fresh root" "$(calls)" "--metric-name RootCAExpiryWarning --value 0 "
assert_contains "IntermediateCAExpiryWarning is 0" "$(calls)" "--metric-name IntermediateCAExpiryWarning --value 0 "
assert_contains "CAExpired is 0" "$(calls)" "--metric-name CAExpired --value 0 "
[[ "$(cat "${WORK}/out.log")" =~ Root\ CA:\ (7299|7300)\ days\ left ]] && pass "the log says how many days are left" || fail "the log says how many days are left" "$(head -1 "${WORK}/out.log")"

DAY=86400
reset; CERT_METRICS_NOW=$(( $(date +%s) + (7300 - 730) * DAY )) "${SCRIPT}" check-expiry > /dev/null 2>&1
assert_contains "the Root CA warning starts at 730 days" "$(calls)" "--metric-name RootCAExpiryWarning --value 1 "
assert_contains "the Intermediate CA warning is on by then too" "$(calls)" "--metric-name IntermediateCAExpiryWarning --value 1 "
reset; CERT_METRICS_NOW=$(( $(date +%s) + (7300 - 732) * DAY )) "${SCRIPT}" check-expiry > /dev/null 2>&1
assert_contains "more than 730 days left is not yet a warning" "$(calls)" "--metric-name RootCAExpiryWarning --value 0 "
reset; CERT_METRICS_NOW=$(( $(date +%s) + (3650 - 1275) * DAY )) "${SCRIPT}" check-expiry > /dev/null 2>&1
assert_contains "the Intermediate CA warning starts at 1275 days (2W + 1 year)" "$(calls)" "--metric-name IntermediateCAExpiryWarning --value 1 "
assert_contains "the Root CA is still fine at that time" "$(calls)" "--metric-name RootCAExpiryWarning --value 0 "
reset; CERT_METRICS_NOW=$(( $(date +%s) + (3650 - 1277) * DAY )) "${SCRIPT}" check-expiry > /dev/null 2>&1
assert_contains "more than 1275 days left is not yet a warning" "$(calls)" "--metric-name IntermediateCAExpiryWarning --value 0 "
reset; CERT_METRICS_NOW=$(( $(date +%s) + 1100 * DAY )) "${SCRIPT}" check-expiry > /dev/null 2>&1
assert_contains "an expired Enrollment CA raises CAExpired" "$(calls)" "--metric-name CAExpired --value 1 "
reset; CERT_METRICS_NOW=$(( $(date +%s) + 1000 * DAY )) "${SCRIPT}" check-expiry > /dev/null 2>&1
assert_contains "no CAExpired while the Enrollment CA is valid" "$(calls)" "--metric-name CAExpired --value 0 "
reset; PKI_ROOT_WARN_DAYS=8000 "${SCRIPT}" check-expiry > /dev/null 2>&1
assert_contains "the warning threshold is a setting" "$(calls)" "--metric-name RootCAExpiryWarning --value 1 "
reset; PKI_ROOT_WARN_DAYS=abc "${SCRIPT}" check-expiry > "${WORK}/out.log" 2>&1; rc=$?
assert_eq "a bad threshold exits 2" "${rc}" "2"
assert_eq "and sends nothing" "$(ncalls)" "0"

echo "unreadable certificate"
echo "not a certificate" > "${FILES}/enrollment-ca.pem"
reset; "${SCRIPT}" check-expiry > "${WORK}/out.log" 2>&1; rc=$?
assert_eq "exit code 0" "${rc}" "0"
assert_eq "nothing is emitted rather than a wrong 0" "$(ncalls)" "0"
assert_contains "the log names the file" "$(cat "${WORK}/out.log")" "cannot read"

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
