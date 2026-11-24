#!/bin/bash
# Tests for the Let's Encrypt renewal of #130: docker-container/scripts/certbot-renew.sh, the cron line
# that start-tak.sh writes, and the failure metric of letsencrypt-request-cert.sh.
# Stub `certbot` and `aws` commands stand in for Let's Encrypt and CloudWatch. Needs bash and coreutils.
# Run from the repository root:  test/KmsCa/test-certbot-renew.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${REPO_ROOT}/docker-container/scripts"
RENEW="${SCRIPTS}/certbot-renew.sh"
REQUEST="${SCRIPTS}/letsencrypt-request-cert.sh"
START_TAK="${SCRIPTS}/start-tak.sh"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete 2> /dev/null' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "expected to contain '$3', got '$2'"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1" "must not contain '$3'"; }

# --- stubs -------------------------------------------------------------------------------------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/certbot" <<'EOF'
#!/bin/bash
# records its arguments and the variables the deploy hook needs; STUB_CERTBOT_RC is the exit status
{ echo "args: $*"; echo "ECS_Cluster_Name=${ECS_Cluster_Name:-unset}"; } >> "${STUB_LOG}/certbot.log"
exit "${STUB_CERTBOT_RC:-0}"
EOF
cat > "${WORK}/bin/aws" <<'EOF'
#!/bin/bash
echo "$*" >> "${STUB_LOG}/aws.log"
case "$*" in
  *describe-services*) echo 1 ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/certbot" "${WORK}/bin/aws"
export STUB_LOG="${WORK}/log"
mkdir -p "${STUB_LOG}"
reset_logs() { : > "${STUB_LOG}/certbot.log"; : > "${STUB_LOG}/aws.log"; }
# a cron-like environment: nothing but the basics
cron_run() { # command...
  env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin" SHELL=/bin/sh LOGNAME=root STUB_LOG="${STUB_LOG}" \
    TAK_CRON_ENV_FILE="${ENV_FILE}" CLUSTER_LOCK_DIR="${WORK}/locks" STUB_CERTBOT_RC="${STUB_CERTBOT_RC:-0}" "$@"
}
ENV_FILE="${WORK}/tak-cron.env"

echo "== write-env"
env -i PATH="${WORK}/bin:/usr/bin:/bin" ECS_Cluster_Name="TAK-Demo-BaseInfra" ECS_Service_Name="TAK-Demo-TakInfra-TakServer" \
  StackName="TAK-Demo-TakInfra" AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="/v2/credentials/abc" AWS_REGION="ap-southeast-6" \
  AWS_DEFAULT_REGION="ap-southeast-6" SOME_PASSWORD="do-not-copy" TAKSERVER_X="no" \
  TAK_CRON_ENV_FILE="${ENV_FILE}" "${RENEW}" write-env
assert_eq "the file is private" "$(stat -c %a "${ENV_FILE}")" "600"
content="$(cat "${ENV_FILE}")"
for v in ECS_Cluster_Name ECS_Service_Name StackName AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_REGION AWS_DEFAULT_REGION; do
  assert_contains "${v} is saved" "${content}" "export ${v}="
done
assert_not_contains "other variables are not copied" "${content}" "SOME_PASSWORD"
assert_not_contains "TAKSERVER_* is not copied" "${content}" "TAKSERVER_X"
env -i PATH="${WORK}/bin:/usr/bin:/bin" ECS_Cluster_Name="a value with 'quotes' and \$dollar" TAK_CRON_ENV_FILE="${ENV_FILE}" "${RENEW}" write-env
assert_eq "a value with spaces, quotes and a dollar sign survives" \
  "$(env -i bash -c "source '${ENV_FILE}'; printf %s \"\${ECS_Cluster_Name}\"")" "a value with 'quotes' and \$dollar"
"${RENEW}" bogus 2> /dev/null
assert_eq "an unknown argument is refused" "$?" "64"
env -i PATH="${WORK}/bin:/usr/bin:/bin" ECS_Cluster_Name="TAK-Demo-BaseInfra" StackName="TAK-Demo-TakInfra" AWS_REGION="ap-southeast-6" \
  TAK_CRON_ENV_FILE="${ENV_FILE}" "${RENEW}" write-env

echo "== renewal"
reset_logs
out="$(cron_run "${RENEW}" 2>&1)"
rc=$?
assert_eq "success: exit 0" "${rc}" "0"
assert_contains "certbot runs as 'certbot -q renew'" "$(cat "${STUB_LOG}/certbot.log")" "args: -q renew"
assert_contains "the deploy hook sees ECS_Cluster_Name although cron gave the job no environment" "$(cat "${STUB_LOG}/certbot.log")" "ECS_Cluster_Name=TAK-Demo-BaseInfra"
assert_eq "success: no metric" "$(grep -c put-metric-data "${STUB_LOG}/aws.log")" "0"
assert_eq "the lock is released" "$([[ -e "${WORK}/locks/certbot-renew.lock" ]] && echo held || echo free)" "free"

reset_logs
out="$(STUB_CERTBOT_RC=3 cron_run "${RENEW}" 2>&1)"
rc=$?
assert_eq "failure: certbot's exit status is returned" "${rc}" "3"
assert_contains "failure: it says so" "${out}" "FAILED with status 3"
metric="$(grep put-metric-data "${STUB_LOG}/aws.log")"
assert_contains "failure: CertbotRenewalFailure is emitted" "${metric}" "--metric-name CertbotRenewalFailure"
assert_contains "failure: value 1" "${metric}" "--value 1"
assert_contains "failure: with the Stack dimension from the saved environment" "${metric}" "--dimensions Stack=TAK-Demo-TakInfra"
assert_contains "failure: in the namespace of the alarms" "${metric}" "--namespace TAK/Certificates"
assert_eq "the lock is released after a failure" "$([[ -e "${WORK}/locks/certbot-renew.lock" ]] && echo held || echo free)" "free"

reset_logs
mkdir -p "${WORK}/locks"
printf "other:1:1:1 60 othernode\n" > "${WORK}/locks/certbot-renew.lock"
out="$(cron_run "${RENEW}" 2>&1)"
rc=$?
assert_eq "another node renews: exit 0" "${rc}" "0"
assert_contains "another node renews: skipped" "${out}" "another node is renewing: skipped"
assert_eq "another node renews: certbot not run" "$(wc -l < "${STUB_LOG}/certbot.log")" "0"
assert_eq "another node renews: no metric" "$(grep -c put-metric-data "${STUB_LOG}/aws.log")" "0"
find "${WORK}/locks/certbot-renew.lock" -delete

reset_logs
ENV_FILE="${WORK}/missing.env"
out="$(cron_run "${RENEW}" 2>&1)"
assert_contains "no environment file: a warning, and certbot still runs" "${out}" "WARNING"
assert_contains "no environment file: certbot ran" "$(cat "${STUB_LOG}/certbot.log")" "args: -q renew"
ENV_FILE="${WORK}/tak-cron.env"

echo "== the cron line that start-tak.sh writes"
# The block of start-tak.sh, pointed at a temp file
BLOCK="$(sed -n '/^if \[ -e "\/etc\/cron.d\/certbot" \] && ! grep -q "certbot-renew.sh"/,/^fi$/p' "${START_TAK}")"
[[ -n "${BLOCK}" ]] && pass "the block is in start-tak.sh" || fail "the block is in start-tak.sh"
rewrite() { # file
  eval "${BLOCK//\/etc\/cron.d\/certbot/$1}"
}
CRON="${WORK}/certbot.cron"
# the line of the Ubuntu 22.04 certbot package (the base image of the container is eclipse-temurin:17-jammy)
cat > "${CRON}" <<'EOF2'
0 */12 * * * root test -x /usr/bin/certbot -a \! -d /run/systemd/system && perl -e 'sleep int(rand(43200))' && certbot -q renew
EOF2
rewrite "${CRON}"
assert_contains "the plain line runs certbot-renew.sh" "$(cat "${CRON}")" "&& /opt/tak/scripts/certbot-renew.sh"
assert_not_contains "the plain line no longer calls certbot directly" "$(cat "${CRON}")" "certbot -q renew"
assert_contains "the random sleep stays before it" "$(cat "${CRON}")" "perl -e 'sleep int(rand(43200))' && /opt/tak/scripts/certbot-renew.sh"
assert_eq "still one line" "$(wc -l < "${CRON}")" "1"
once="$(cat "${CRON}")"
rewrite "${CRON}"
assert_eq "a second run changes nothing" "$(cat "${CRON}")" "${once}"
cat > "${CRON}" <<'EOF2'
0 */12 * * * root test -x /usr/bin/certbot -a \! -d /run/systemd/system && perl -e 'sleep int(rand(43200))' && /opt/tak/scripts/cluster-lock.sh run --wait 0 certbot-renew -- certbot -q renew
EOF2
rewrite "${CRON}"
assert_contains "a line wrapped by the first version (#7) is replaced" "$(cat "${CRON}")" "&& /opt/tak/scripts/certbot-renew.sh"
assert_not_contains "...and no longer calls cluster-lock.sh itself" "$(cat "${CRON}")" "cluster-lock.sh"

echo "== a failed request at start (letsencrypt-request-cert.sh)"
reset_logs
out="$(env -i HOME="${WORK}" PATH="${WORK}/bin:/usr/bin:/bin" STUB_LOG="${STUB_LOG}" StackName="TAK-Demo-TakInfra" \
  ECS_Cluster_Name=c ECS_Service_Name=s ECS_READINESS_TIMEOUT=0 CERTBOT_ATTEMPTS=3 CERTBOT_RETRY_DELAY=0 STUB_CERTBOT_RC=1 \
  TAKSERVER_QuickConnect_LetsEncrypt_Domain=ops.dev.tak.nz TAKSERVER_QuickConnect_LetsEncrypt_CertType=staging \
  TAKSERVER_QuickConnect_LetsEncrypt_Email=admin@tak.nz "${REQUEST}" 2>&1)"
rc=$?
assert_eq "exit 1 after the attempts" "${rc}" "1"
assert_eq "certbot was tried 3 times" "$(grep -c '^args:' "${STUB_LOG}/certbot.log")" "3"
assert_contains "it says so" "${out}" "Failed after 3 attempts"
metric="$(grep put-metric-data "${STUB_LOG}/aws.log")"
assert_contains "CertbotRenewalFailure is emitted" "${metric}" "--metric-name CertbotRenewalFailure"
assert_eq "once" "$(grep -c put-metric-data "${STUB_LOG}/aws.log")" "1"

echo
echo "passed ${PASS}, failed ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
