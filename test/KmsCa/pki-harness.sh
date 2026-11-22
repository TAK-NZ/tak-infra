#!/bin/bash
# Shared set-up of the PKI tests (test-pki-bootstrap.sh, test-server-cert-rotate.sh): assertion helpers,
# SoftHSM2 tokens that stand in for the two KMS keys, a wrapper of kms-ca.sh that uses them, and a stub
# `aws`. The stub keeps Secrets Manager secrets as files, logs put-metric-data to ${STUB_LOG}/metrics.log
# and ecs update-service to ${STUB_LOG}/ecs.log (STUB_ECS_FAILS=1 makes the latter fail). Every call is also
# logged to ${STUB_LOG}/aws.log.
# Meant to be sourced.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KMS_CA_REAL="${REPO_ROOT}/docker-container/scripts/kms-ca.sh"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete 2> /dev/null' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "expected to contain '$3', got '$2'"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1" "must not contain '$3'"; }
assert_file() { [[ -s "$2" ]] && pass "$1" || fail "$1" "missing or empty: $2"; }
assert_no_file() { [[ ! -e "$2" && ! -L "$2" ]] && pass "$1" || fail "$1" "must not exist: $2"; }

for tool in openssl softhsm2-util pkcs11-tool jq keytool; do
  command -v "${tool}" > /dev/null || { echo "missing tool: ${tool}"; exit 1; }
done
SOFTHSM_LIB="$(ls /usr/lib/softhsm/libsofthsm2.so /usr/lib/*/softhsm/libsofthsm2.so 2> /dev/null | head -1)"
ENGINE_SO="$(ls /usr/lib/*/engines-3/pkcs11.so /usr/lib/*/engines-3/libpkcs11.so 2> /dev/null | head -1)"
[[ -f "${SOFTHSM_LIB}" && -f "${ENGINE_SO}" ]] || { echo "SoftHSM or the libp11 engine not found"; exit 1; }

# --- SoftHSM tokens for the two KMS keys ---------------------------------------------------
export SOFTHSM2_CONF="${WORK}/softhsm2.conf"
mkdir -p "${WORK}/tokens" "${WORK}/bin" "${WORK}/secrets"
printf 'directories.tokendir = %s\nobjectstore.backend = file\nlog.level = ERROR\n' "${WORK}/tokens" > "${SOFTHSM2_CONF}"
for label in root-ca-01 intermediate-ca-01 intermediate-ca-02; do
  softhsm2-util --init-token --free --label "${label}" --so-pin 12345678 --pin 1234 > /dev/null
  pkcs11-tool --module "${SOFTHSM_LIB}" --token-label "${label}" --login --pin 1234 \
    --keypairgen --key-type rsa:2048 --label "${label}" --id 01 > /dev/null 2>&1 || { echo "could not create key for ${label}"; exit 1; }
done
cat > "${WORK}/openssl-engine.cnf" <<EOF
openssl_conf = openssl_init
[openssl_init]
engines = engine_section
[engine_section]
pkcs11 = pkcs11_section
[pkcs11_section]
engine_id = pkcs11
dynamic_path = ${ENGINE_SO}
MODULE_PATH = ${SOFTHSM_LIB}
PIN = 1234
init = 0
[req]
default_bits = 2048
distinguished_name = req_dn
[req_dn]
EOF
# The engine config (which logs in with a PIN) is only for kms-ca.sh, like the real module needs no PIN;
# software keys in pki-bootstrap.sh are made without it.
cat > "${WORK}/kms-ca-wrapper.sh" <<EOF
#!/bin/bash
export OPENSSL_CONF="${WORK}/openssl-engine.cnf" PKCS11_MODULE_PATH="${SOFTHSM_LIB}" KMS_CA_SKIP_CONFIG=1
exec "${KMS_CA_REAL}" "\$@"
EOF
chmod +x "${WORK}/kms-ca-wrapper.sh"

# --- stub aws: secrets are files ------------------------------------------------------------
cat > "${WORK}/bin/aws" <<'EOF'
#!/bin/bash
echo "$*" >> "${STUB_LOG}/aws.log"
case "$1 $2" in
  "cloudwatch put-metric-data") echo "$*" >> "${STUB_LOG}/metrics.log"; exit 0 ;;
  "sns publish")
    shift 2; topic=""; subject=""; message=""
    while [[ $# -gt 0 ]]; do case "$1" in --topic-arn) topic="$2"; shift 2 ;; --subject) subject="$2"; shift 2 ;; --message) message="$2"; shift 2 ;; *) shift ;; esac; done
    echo "topic=${topic} subject=${subject}" >> "${STUB_LOG}/sns.log"; printf '%s\n' "${message}" > "${STUB_LOG}/sns-last.txt"; echo '{"MessageId":"x"}'; exit 0 ;;
  "ecs update-service") echo "$*" >> "${STUB_LOG}/ecs.log"; [[ -n "${STUB_ECS_FAILS:-}" ]] && exit 1; echo '{}'; exit 0 ;;
  "secretsmanager put-secret-value" | "secretsmanager get-secret-value") ;;
  "secretsmanager delete-secret")
    shift 2; id=""; window=""; force=0
    while [[ $# -gt 0 ]]; do case "$1" in --secret-id) id="$2"; shift 2 ;; --recovery-window-in-days) window="$2"; shift 2 ;; --force-delete-without-recovery) force=1; shift ;; *) shift ;; esac; done
    dest="${STUB_SECRETS}/$(echo "${id}" | tr '/:' '__')"
    echo "id=${id} window=${window} force=${force}" >> "${STUB_LOG}/delete.log"
    [[ -f "${dest}" ]] || { echo "ResourceNotFoundException" >&2; exit 254; }
    mv "${dest}" "${dest}.deleted"; echo '{}'; exit 0 ;;
  "secretsmanager describe-secret"|"secretsmanager create-secret")
    sub="$2"; shift 2
    id=""; file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --secret-id|--name) id="$2"; shift 2 ;;
        --secret-binary) file="${2#fileb://}"; shift 2 ;;
        *) shift ;;
      esac
    done
    dest="${STUB_SECRETS}/$(echo "${id}" | tr '/:' '__')"
    if [[ "${sub}" == "describe-secret" ]]; then
      # --query DeletedDate --output text: None, or a date for a secret that is scheduled for deletion
      if [[ -f "${dest}.deleted" ]]; then echo "1700000000.0"; exit 0; fi
      [[ -f "${dest}" ]] || { echo "ResourceNotFoundException" >&2; exit 254; }
      echo 'None'; exit 0
    fi
    [[ -f "${dest}" || -f "${dest}.deleted" ]] && { echo "ResourceExistsException" >&2; exit 254; }
    [[ -n "${STUB_SECRET_WRITE_FAILS:-}" ]] && { echo "AccessDenied" >&2; exit 254; }
    cp "${file}" "${dest}"; echo '{}'; exit 0 ;;
  *) echo "stub aws: unexpected: $*" >&2; exit 90 ;;
esac
sub="$2"; shift 2
id=""; file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --secret-id) id="$2"; shift 2 ;;
    --secret-binary) file="${2#fileb://}"; shift 2 ;;
    *) shift ;;
  esac
done
dest="${STUB_SECRETS}/$(echo "${id}" | tr '/:' '__')"
if [[ "${sub}" == "put-secret-value" ]]; then
  [[ -n "${STUB_SECRET_WRITE_FAILS:-}" ]] && { echo "AccessDenied" >&2; exit 254; }
  cp "${file}" "${dest}"; echo '{}'
else
  # ${STUB_LOG}/read-fails holds a number: that many reads fail (a secret that is not readable yet), then it counts down
  if [[ -s "${STUB_LOG}/read-fails" ]] && (( $(cat "${STUB_LOG}/read-fails") > 0 )); then
    echo $(( $(cat "${STUB_LOG}/read-fails") - 1 )) > "${STUB_LOG}/read-fails"; echo "ResourceNotFoundException" >&2; exit 254
  fi
  [[ -f "${dest}" ]] || { echo "ResourceNotFoundException" >&2; exit 254; }
  base64 -w0 "${dest}"; echo
fi
EOF
chmod +x "${WORK}/bin/aws"
mkdir -p "${WORK}/stublog"
export PATH="${WORK}/bin:${PATH}" STUB_SECRETS="${WORK}/secrets" STUB_LOG="${WORK}/stublog"

export PKI_ENV_LABEL=Try PKI_ENROLLMENT_CA_SECRET="stack/TAK-Server/Enrollment-CA"
export PKI_KMS_CA_KEYS="root-ca-01=11111111-1111-4111-8111-111111111111,intermediate-ca-01=22222222-2222-4222-8222-222222222222"
export PKI_SERVER_NAMES="ops.try.tak.nz,tak.try.tak.nz"
export PKI_KMS_CA_SCRIPT="${WORK}/kms-ca-wrapper.sh"

fresh() { # name -> exports FILES/TMPFS for a clean stack
  FILES="${WORK}/$1/files"; TMPFS="${WORK}/$1/tmpfs"
  mkdir -p "${FILES}"
  export PKI_FILES_DIR="${FILES}" PKI_TMPFS_DIR="${TMPFS}"
}
