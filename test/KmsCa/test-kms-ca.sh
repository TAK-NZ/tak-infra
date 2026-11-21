#!/bin/bash
# Tests for docker-container/scripts/kms-ca.sh (#136).
#
# The script talks to OpenSSL through the PKCS#11 engine. These tests replace the aws-kms-pkcs11
# module with SoftHSM2, which exposes the same interface (a token per key label, no PIN prompt
# from the script), so everything except the KMS call itself is tested without AWS credentials.
# The real module was validated against KMS in the #134 spike.
#
# Requirements: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc (pkcs11-tool), jq.
#   Ubuntu: sudo apt-get install -y softhsm2 opensc libengine-pkcs11-openssl jq
# Run from the repository root:  test/KmsCa/test-kms-ca.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/docker-container/scripts/kms-ca.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       $2"; }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1" "expected to contain '$3', got '$2'"; }
assert_ok() { local d="$1"; shift; if "$@" > "${WORK}/out.log" 2>&1; then pass "${d}"; else fail "${d}" "$(tail -3 "${WORK}/out.log")"; fi; }
assert_fails() {
  local d="$1" pattern="$2"; shift 2
  if "$@" > "${WORK}/out.log" 2>&1; then fail "${d}" "command succeeded"; return; fi
  if grep -q -- "${pattern}" "${WORK}/out.log"; then pass "${d}"; else fail "${d}" "message was: $(tail -2 "${WORK}/out.log")"; fi
}

# --- tool check ---------------------------------------------------------------------------
for tool in openssl softhsm2-util pkcs11-tool jq; do
  command -v "${tool}" > /dev/null || { echo "missing tool: ${tool}"; exit 1; }
done
SOFTHSM_LIB="$(ls /usr/lib/softhsm/libsofthsm2.so /usr/lib/*/softhsm/libsofthsm2.so 2> /dev/null | head -1)"
ENGINE_SO="$(ls /usr/lib/*/engines-3/pkcs11.so /usr/lib/*/engines-3/libpkcs11.so 2> /dev/null | head -1)"
[[ -f "${SOFTHSM_LIB}" ]] || { echo "SoftHSM library not found"; exit 1; }
[[ -f "${ENGINE_SO}" ]] || { echo "libp11 OpenSSL engine not found"; exit 1; }

# --- SoftHSM tokens standing in for KMS keys ----------------------------------------------
export SOFTHSM2_CONF="${WORK}/softhsm2.conf"
mkdir -p "${WORK}/tokens"
printf 'directories.tokendir = %s\nobjectstore.backend = file\nlog.level = ERROR\n' "${WORK}/tokens" > "${SOFTHSM2_CONF}"

for label in root-ca-01 root-ca-02 intermediate-ca-01 intermediate-ca-02; do
  softhsm2-util --init-token --free --label "${label}" --so-pin 12345678 --pin 1234 > /dev/null
  slot="$(softhsm2-util --show-slots | awk -v l="${label}" '/^Slot /{s=$2} $1=="Label:" && $2==l{print s}' | head -1)"
  pkcs11-tool --module "${SOFTHSM_LIB}" --token-label "${label}" --login --pin 1234 \
    --keypairgen --key-type rsa:2048 --label "${label}" --id 01 > /dev/null 2>&1 \
    || { echo "could not create key for ${label}"; exit 1; }
done

# The engine logs in with a PIN from the OpenSSL config (the real module needs no PIN)
cat > "${WORK}/openssl.cnf" <<EOF
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
export OPENSSL_CONF="${WORK}/openssl.cnf"
export PKCS11_MODULE_PATH="${SOFTHSM_LIB}"
export KMS_CA_SKIP_CONFIG=1
export PKI_ENV_LABEL="Try"

cd "${WORK}"
subject_of() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed "s/^subject=//"; }
pubkey_hash() { openssl x509 -in "$1" -noout -pubkey | sha256sum | cut -d' ' -f1; }

# --- naming ------------------------------------------------------------------------------
echo "naming"
assert_eq "root CN" "$("${SCRIPT}" common-name root-ca-01)" "TAK.NZ Try Root CA 01"
assert_eq "intermediate CN" "$("${SCRIPT}" common-name intermediate-ca-12)" "TAK.NZ Try Intermediate CA 12"
assert_eq "environment label with a space" "$(PKI_ENV_LABEL='Dev Test' "${SCRIPT}" common-name root-ca-02)" "TAK.NZ Dev Test Root CA 02"
assert_fails "rejects label root-ca-00" "invalid key label" "${SCRIPT}" common-name root-ca-00
assert_fails "rejects label without number" "invalid key label" "${SCRIPT}" common-name root-ca
assert_fails "rejects label with path characters" "invalid key label" "${SCRIPT}" common-name '../root-ca-01'
assert_fails "rejects other tiers" "invalid key label" "${SCRIPT}" common-name enrollment-ca-01
assert_fails "rejects environment label with a slash" "invalid PKI_ENV_LABEL" env PKI_ENV_LABEL='a/b' "${SCRIPT}" common-name root-ca-01
assert_fails "rejects environment label with an injected DN" "invalid PKI_ENV_LABEL" env PKI_ENV_LABEL='x,CN=evil' "${SCRIPT}" common-name root-ca-01
assert_fails "requires PKI_ENV_LABEL" "PKI_ENV_LABEL is not set" env -u PKI_ENV_LABEL "${SCRIPT}" common-name root-ca-01

# --- module config -----------------------------------------------------------------------
echo "config"
UUID1="1234abcd-0000-4000-8000-0123456789ab"
UUID2="abcdef01-1111-4111-8111-0123456789ab"
CFG_HOME="${WORK}/cfg"
run_config() { env -u KMS_CA_SKIP_CONFIG KMS_CA_CONFIG_HOME="${CFG_HOME}" PKI_KMS_REGION=ap-southeast-6 PKI_KMS_CA_KEYS="$1" "${SCRIPT}" config; }
assert_ok "writes the config" run_config "root-ca-01=${UUID1},intermediate-ca-01=${UUID2}"
CFG="${CFG_HOME}/aws-kms-pkcs11/config.json"
assert_eq "config has both slots" "$(jq -r '.slots | length' "${CFG}")" "2"
assert_eq "root slot" "$(jq -c '.slots[0]' "${CFG}")" "{\"label\":\"root-ca-01\",\"kms_key_id\":\"${UUID1}\",\"aws_region\":\"ap-southeast-6\"}"
assert_eq "config file is private" "$(stat -c %a "${CFG}")" "600"
assert_fails "rejects a malformed key id" "invalid KMS key id" run_config "root-ca-01=not-a-key"
assert_fails "rejects an entry without =" "expected label=key-id" run_config "root-ca-01"
assert_fails "rejects a bad label" "invalid key label" run_config "evil=${UUID1}"
assert_fails "rejects an injected region" "invalid Region" env -u KMS_CA_SKIP_CONFIG PKI_KMS_REGION='x","y' PKI_KMS_CA_KEYS="root-ca-01=${UUID1}" "${SCRIPT}" config
assert_fails "requires keys" "PKI_KMS_CA_KEYS is not set" env -u KMS_CA_SKIP_CONFIG -u PKI_KMS_CA_KEYS PKI_KMS_REGION=ap-southeast-2 "${SCRIPT}" config

# --- serial numbers ----------------------------------------------------------------------
echo "serials"
bad=0
for _ in $(seq 1 200); do
  s="$(KMS_CA_SOURCE_ONLY=1 bash -c "source '${SCRIPT}'; random_serial")"
  [[ "${s}" =~ ^0x[0-7][0-9a-f]{15}$ ]] || bad=$((bad + 1))
done
assert_eq "200 serials are 64-bit and never negative" "${bad}" "0"

# --- Root CA 01 --------------------------------------------------------------------------
echo "root CA"
assert_ok "self-signs Root CA 01" "${SCRIPT}" root-self-sign root-ca-01 root1.pem 7300
assert_eq "root subject" "$(subject_of root1.pem)" "CN=TAK.NZ Try Root CA 01,O=TAK.NZ"
assert_contains "root is a CA with pathlen 2" "$(openssl x509 -in root1.pem -noout -ext basicConstraints)" "pathlen:2"
assert_contains "root key usage is certSign and CRLSign" "$(openssl x509 -in root1.pem -noout -ext keyUsage)" "Certificate Sign, CRL Sign"
assert_fails "refuses an intermediate label as root" "not a Root CA key" "${SCRIPT}" root-self-sign intermediate-ca-01 x.pem 100
assert_fails "refuses days of 0" "invalid number of days" "${SCRIPT}" root-self-sign root-ca-01 x.pem 0
assert_fails "refuses days of text" "invalid number of days" "${SCRIPT}" root-self-sign root-ca-01 x.pem '10; rm -rf /'

# --- Intermediate CA 01 issued by Root CA 01 -----------------------------------------------
echo "intermediate CA"
assert_ok "CSR for Intermediate CA 01" "${SCRIPT}" csr intermediate-ca-01 inter1.csr
assert_contains "CSR subject" "$(openssl req -in inter1.csr -noout -subject -nameopt RFC2253)" "CN=TAK.NZ Try Intermediate CA 01,O=TAK.NZ"
assert_ok "Root CA 01 issues Intermediate CA 01" "${SCRIPT}" issue-ca root-ca-01 root1.pem inter1.csr inter1.pem 3650
assert_contains "intermediate has pathlen 1" "$(openssl x509 -in inter1.pem -noout -ext basicConstraints)" "pathlen:1"
assert_eq "intermediate issuer is Root CA 01" "$(openssl x509 -in inter1.pem -noout -issuer -nameopt RFC2253)" "issuer=CN=TAK.NZ Try Root CA 01,O=TAK.NZ"
ROOT_SKI="$(openssl x509 -in root1.pem -noout -ext subjectKeyIdentifier | tail -1 | tr -d ' ')"
assert_contains "authority key id is the root's key id" "$(openssl x509 -in inter1.pem -noout -ext authorityKeyIdentifier | tr -d ' ')" "${ROOT_SKI}"
assert_ok "intermediate chains to the root" openssl verify -CAfile root1.pem inter1.pem

# --- signing with the wrong key must fail and leave nothing behind -------------------------
echo "wrong key"
assert_ok "CSR for Intermediate CA 02" "${SCRIPT}" csr intermediate-ca-02 inter2.csr
assert_fails "issuer label that does not match the issuer certificate" "could not sign" \
  "${SCRIPT}" issue-ca root-ca-02 root1.pem inter2.csr wrong.pem 3650
[[ ! -e wrong.pem ]] && pass "no certificate left behind" || fail "no certificate left behind" "wrong.pem exists"

# --- cross-certification: Root CA 02 certifies the SAME Intermediate CA 01 key and subject ---
echo "cross-certification"
assert_ok "self-signs Root CA 02" "${SCRIPT}" root-self-sign root-ca-02 root2.pem 7300
assert_ok "Root CA 02 certifies Intermediate CA 01" "${SCRIPT}" issue-ca root-ca-02 root2.pem inter1.csr inter1_by_root2.pem 3650
assert_eq "same subject" "$(subject_of inter1_by_root2.pem)" "$(subject_of inter1.pem)"
assert_eq "same public key" "$(pubkey_hash inter1_by_root2.pem)" "$(pubkey_hash inter1.pem)"
assert_contains "different issuer" "$(openssl x509 -in inter1_by_root2.pem -noout -issuer -nameopt RFC2253)" "Root CA 02"

# --- Enrollment Signing CA (software key) and a server certificate -------------------------
echo "enrollment CA and server certificate"
# Software keys are generated without the engine config (the engine would take over key generation)
soft_csr() { # <key out> <csr out> <subject>
  env OPENSSL_CONF=/dev/null openssl genrsa -out "$1" 2048 > keygen.log 2>&1 \
    && env OPENSSL_CONF=/dev/null openssl req -new -key "$1" -subj "$3" -out "$2" >> keygen.log 2>&1 || cat keygen.log
}
soft_csr cl1.key cl1.csr "/O=TAK.NZ/CN=TAK.NZ Try Enrollment CA 01"
assert_ok "Intermediate CA 01 issues the Enrollment CA" "${SCRIPT}" issue-ca intermediate-ca-01 inter1.pem cl1.csr cl1.pem 365
assert_contains "enrollment CA has pathlen 0" "$(openssl x509 -in cl1.pem -noout -ext basicConstraints)" "pathlen:0"
assert_ok "chain Cl -> S -> R" openssl verify -CAfile root1.pem -untrusted inter1.pem cl1.pem

cat > tak_ext.cfg <<'EOF'
[ server ]
basicConstraints=critical,CA:FALSE
keyUsage=critical, digitalSignature, keyEncipherment
extendedKeyUsage = critical, clientAuth, serverAuth
subjectAltName=DNS:takserver,DNS:tak.try.tak.nz
EOF
soft_csr l1.key l1.csr "/CN=takserver"
assert_ok "Intermediate CA 01 signs a server certificate (makeCert.sh style)" "${SCRIPT}" sign intermediate-ca-01 inter1.pem l1.csr l1.pem 330 server tak_ext.cfg
assert_ok "server certificate chains to the root" openssl verify -CAfile root1.pem -untrusted inter1.pem l1.pem
assert_contains "server certificate keeps its SAN" "$(openssl x509 -in l1.pem -noout -ext subjectAltName)" "tak.try.tak.nz"
assert_ok "server certificate also verifies via the cross-certificate" openssl verify -CAfile root2.pem -untrusted inter1_by_root2.pem l1.pem
assert_fails "sign needs an existing extension file" "extension file not found" "${SCRIPT}" sign intermediate-ca-01 inter1.pem l1.csr l1b.pem 330 server missing.cfg

# --- CRL -----------------------------------------------------------------------------------
echo "crl"
assert_ok "Intermediate CA 01 signs a CRL" "${SCRIPT}" crl intermediate-ca-01 inter1.pem inter1.crl 730
assert_ok "CRL verifies against the intermediate" openssl crl -in inter1.crl -noout -verify -CAfile inter1.pem
assert_fails "CRL with the wrong key fails" "could not sign a CRL" "${SCRIPT}" crl root-ca-02 inter1.pem bad.crl 730

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
