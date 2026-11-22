#!/bin/bash
# Tests for docker-container/scripts/admin-p12-reexport.sh (#132, interim fix for stacks with the PKI of the
# TAK Server scripts). Needs openssl 3 with the legacy provider, jq not needed. A stub `aws` stands in for
# Secrets Manager.
# Run from the repository root:  test/KmsCa/test-admin-p12-reexport.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/docker-container/scripts/admin-p12-reexport.sh"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete 2> /dev/null' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "expected to contain '$3', got '$2'"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1" "must not contain '$3'"; }
openssl list -providers -provider legacy -provider default > /dev/null 2>&1 || { echo "openssl 3 with the legacy provider is needed"; exit 1; }

# --- stub aws -------------------------------------------------------------------------------
mkdir -p "${WORK}/bin" "${WORK}/log"
cat > "${WORK}/bin/aws" <<'EOF'
#!/bin/bash
echo "$*" >> "${STUB_LOG}/aws.log"
[[ "$1 $2" == "secretsmanager put-secret-value" ]] || { echo "stub aws: unexpected: $*" >&2; exit 90; }
file=""
while [[ $# -gt 0 ]]; do [[ "$1" == --secret-binary ]] && file="${2#fileb://}"; shift; done
[[ -n "${STUB_SECRET_CONFLICT:-}" ]] && { echo "An error occurred (ClientRequestTokenConflictException)" >&2; exit 254; }
[[ -n "${STUB_SECRET_FAILS:-}" ]] && { echo "An error occurred (AccessDeniedException)" >&2; exit 254; }
cp "${file}" "${STUB_LOG}/secret.p12"
echo '{}'
EOF
chmod +x "${WORK}/bin/aws"
export PATH="${WORK}/bin:${PATH}" STUB_LOG="${WORK}/log" CLUSTER_LOCK_POLL=0.2 StackName="TAK-Test-TakInfra"

# --- what makeCert.sh makes: a leaf and a two-certificate chain, RC2-40 -----------------------
mkca() { # name issuer-or-self
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/$1.key" -out "${WORK}/$1.pem" -subj "/O=TAK.NZ/CN=$1" -days 30 2> /dev/null
}
mkca ca-root
openssl req -newkey rsa:2048 -nodes -keyout "${WORK}/ca-int.key" -out "${WORK}/ca-int.csr" -subj "/O=TAK.NZ/CN=ca-int" 2> /dev/null
openssl x509 -req -in "${WORK}/ca-int.csr" -CA "${WORK}/ca-root.pem" -CAkey "${WORK}/ca-root.key" -CAcreateserial -out "${WORK}/ca-int.pem" -days 30 2> /dev/null
openssl req -newkey rsa:2048 -nodes -keyout "${WORK}/admin.key" -out "${WORK}/admin.csr" -subj "/O=TAK.NZ/CN=admin" 2> /dev/null
openssl x509 -req -in "${WORK}/admin.csr" -CA "${WORK}/ca-int.pem" -CAkey "${WORK}/ca-int.key" -CAcreateserial -out "${WORK}/admin.pem" -days 30 2> /dev/null
cat "${WORK}/ca-int.pem" "${WORK}/ca-root.pem" > "${WORK}/chain.pem"
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256; }
LEAF_FP="$(fp "${WORK}/admin.pem")"

stack() { # name [-legacy | -legacy -descert | ...]: a files dir with admin.p12 made with the given export options
  local name="$1"
  shift
  FILES="${WORK}/${name}"
  mkdir -p "${FILES}"
  openssl pkcs12 -export "$@" -in "${WORK}/admin.pem" -inkey "${WORK}/admin.key" -certfile "${WORK}/chain.pem" -name admin \
    -out "${FILES}/admin.p12" -passout pass:atakatak 2> /dev/null
  chmod 644 "${FILES}/admin.p12"
  export PKI_FILES_DIR="${FILES}"
  : > "${STUB_LOG}/aws.log"
  rm -f "${STUB_LOG}/secret.p12"
}
run() { "${SCRIPT}" "$@" > "${WORK}/run.log" 2>&1; echo $?; }
readable() { openssl pkcs12 -in "$1" -passin pass:atakatak -nokeys 2> /dev/null | grep -c "BEGIN CERTIFICATE"; }
info() { openssl pkcs12 -legacy -in "$1" -passin pass:atakatak -info -noout 2>&1; }

echo "an RC2-40 admin.p12 (what makeCert.sh writes)"
stack rc2 -legacy
assert_eq "OpenSSL 3 cannot read it without the legacy provider" "$(readable "${FILES}/admin.p12")" "0"
assert_contains "the certificates are RC2-40" "$(info "${FILES}/admin.p12")" "pbeWithSHA1And40BitRC2-CBC"
cp "${FILES}/admin.p12" "${WORK}/rc2-original.p12"
assert_eq "dry run: exit 0" "$(run --dry-run)" "0"
assert_contains "dry run: says nothing was changed" "$(cat "${WORK}/run.log")" "nothing was changed"
assert_eq "dry run: the file is untouched" "$(cmp "${FILES}/admin.p12" "${WORK}/rc2-original.p12" && echo same)" "same"
assert_eq "dry run: no secret call" "$(wc -l < "${STUB_LOG}/aws.log")" "0"
assert_eq "exit 0" "$(run)" "0"
assert_eq "OpenSSL 3 reads it now, without the legacy provider (3 certificates)" "$(readable "${FILES}/admin.p12")" "3"
assert_contains "the certificates are 3DES now" "$(info "${FILES}/admin.p12")" "pbeWithSHA1And3-KeyTripleDES-CBC"
assert_not_contains "no RC2 left" "$(info "${FILES}/admin.p12")" "RC2"
assert_contains "the MAC is SHA-1 (the compat3des profile)" "$(info "${FILES}/admin.p12")" "MAC: sha1"
assert_eq "same leaf certificate" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -nokeys -clcerts 2> /dev/null | openssl x509 -noout -fingerprint -sha256)" "${LEAF_FP}"
assert_eq "same key" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -nocerts -nodes 2> /dev/null | openssl pkey -pubout | sha256sum)" "$(openssl pkey -in "${WORK}/admin.key" -pubout | sha256sum)"
assert_eq "same chain (3 certificates, same fingerprints)" \
  "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -nokeys 2> /dev/null | grep -c BEGIN)" "3"
assert_eq "friendly name admin" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -nokeys -clcerts 2> /dev/null | grep -m1 friendlyName | awk '{print $2}')" "admin"
assert_eq "the old file is kept as admin.p12.rc2" "$(cmp "${FILES}/admin.p12.rc2" "${WORK}/rc2-original.p12" && echo same)" "same"
assert_eq "mode 600" "$(stat -c %a "${FILES}/admin.p12")" "600"
assert_eq "no temporary files" "$(ls "${FILES}" | grep -c '\.new$')" "0"
assert_eq "the work directory is gone" "$(ls /dev/shm 2> /dev/null | grep -c '^admin-p12\.')" "0"
assert_eq "the lock is released" "$([[ -e "${FILES}/.locks/admin-p12-reexport.lock" ]] && echo held || echo free)" "free"
aws_call="$(cat "${STUB_LOG}/aws.log")"
assert_contains "the secret is updated: right name" "${aws_call}" "--secret-id TAK-Test-TakInfra/TAK-Server/Admin-Cert"
assert_contains "the request token is the hash of the file (as start-tak.sh does)" "${aws_call}" "--client-request-token $(sha256sum "${FILES}/admin.p12" | cut -d' ' -f1)"
assert_eq "the secret holds the new file" "$(cmp "${STUB_LOG}/secret.p12" "${FILES}/admin.p12" && echo same)" "same"
assert_not_contains "the log does not contain the password or key material" "$(cat "${WORK}/run.log")" "PRIVATE KEY"

echo "a second run changes nothing"
cp "${FILES}/admin.p12" "${WORK}/after-first.p12"
: > "${STUB_LOG}/aws.log"
assert_eq "exit 0" "$(run)" "0"
assert_contains "it says there is nothing to do" "$(cat "${WORK}/run.log")" "nothing to do"
assert_eq "the file is unchanged" "$(cmp "${FILES}/admin.p12" "${WORK}/after-first.p12" && echo same)" "same"
assert_eq "no secret call" "$(wc -l < "${STUB_LOG}/aws.log")" "0"
assert_eq "the backup is still the RC2 original" "$(cmp "${FILES}/admin.p12.rc2" "${WORK}/rc2-original.p12" && echo same)" "same"

echo "files that are readable already are left alone"
stack compat -legacy -descert
cp "${FILES}/admin.p12" "${WORK}/compat-original.p12"
assert_eq "compat3des: exit 0" "$(run)" "0"
assert_eq "compat3des: unchanged, no backup, no secret call" "$(cmp "${FILES}/admin.p12" "${WORK}/compat-original.p12" && echo same)/$([[ -e "${FILES}/admin.p12.rc2" ]] && echo backup || echo none)/$(wc -l < "${STUB_LOG}/aws.log")" "same/none/0"
stack aes
assert_eq "aes256 (the OpenSSL 3 default): exit 0" "$(run)" "0"
assert_contains "aes256: nothing to do" "$(cat "${WORK}/run.log")" "nothing to do"

echo "errors"
stack wrongpass -legacy
before="$(sha256sum "${FILES}/admin.p12")"
assert_eq "a wrong password: exit 1" "$(P12_PASSWORD=wrong "${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "cannot open"
assert_eq "...and the file is unchanged" "$(sha256sum "${FILES}/admin.p12")" "${before}"
FILES="${WORK}/none"; mkdir -p "${FILES}"; export PKI_FILES_DIR="${FILES}"
assert_eq "no admin.p12: exit 1" "$(run)" "1"
assert_eq "an unknown option: exit 64" "$(run --bogus)" "64"
stack nosecret -legacy
assert_eq "--no-secret: exit 0" "$(run --no-secret)" "0"
assert_eq "--no-secret: the file is replaced, no secret call" "$(readable "${FILES}/admin.p12")/$(wc -l < "${STUB_LOG}/aws.log")" "3/0"
stack failsecret -legacy
assert_eq "the secret update fails: exit 1" "$(STUB_SECRET_FAILS=1 "${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_eq "...the file is already replaced (the next start uploads it)" "$(readable "${FILES}/admin.p12")" "3"
assert_contains "...and the log says so" "$(cat "${WORK}/run.log")" "the next start uploads it"
stack conflict -legacy
assert_eq "the secret already holds the file (same token): exit 0" "$(STUB_SECRET_CONFLICT=1 "${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?)" "0"
stack nostack -legacy
assert_eq "StackName unset: exit 1 (file replaced, secret not named)" "$(env -u StackName "${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "StackName is not set"
stack locked -legacy
mkdir -p "${FILES}/.locks"
printf 'other:1:1:1 60 othernode\n' > "${FILES}/.locks/admin-p12-reexport.lock"
before="$(sha256sum "${FILES}/admin.p12")"
assert_eq "another node runs it: exit 75" "$(CLUSTER_LOCK_WAIT=1 "${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?)" "75"
assert_eq "...and the file is unchanged" "$(sha256sum "${FILES}/admin.p12")" "${before}"

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
