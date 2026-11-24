#!/bin/bash
# kms-ca.sh - sign CA certificates with the Root CA and Intermediate CA keys in AWS KMS (#136).
#
# The private keys never leave KMS. OpenSSL reaches them through the "pkcs11" engine (libp11) and
# the aws-kms-pkcs11 module, which calls kms:Sign with the task role's credentials. Every command
# names the signing key explicitly: unlike TAK's makeCert.sh (which always signs with ca.pem and
# ca-do-not-share.key) nothing here falls back to a default key.
#
# Environment:
#   PKI_ENV_LABEL       environment label in the CA names, e.g. "Try" -> "TAK.NZ Try Root CA 01"
#   PKI_KMS_CA_KEYS     comma separated <label>=<kms key id> pairs, e.g.
#                       "root-ca-01=1234...,intermediate-ca-01=5678..." (set by the CDK stack)
#   PKI_KMS_REGION      Region of the KMS keys (default: AWS_REGION)
#   PKCS11_MODULE_PATH  PKCS#11 module (default: /usr/lib/pkcs11/aws_kms_pkcs11.so)
#   KMS_CA_CONFIG_HOME  where the module config is written (default: /tmp/kms-ca)
#   KMS_CA_SKIP_CONFIG  set to 1 to skip writing the module config (tests use SoftHSM instead)
#
# Naming (see issue #171): a key label such as "intermediate-ca-02" gives the subject
#   O=TAK.NZ, CN=TAK.NZ <PKI_ENV_LABEL> Intermediate CA 02
# The number identifies the key. Every certificate for the same key keeps the same subject.
set -euo pipefail

PKCS11_MODULE_PATH="${PKCS11_MODULE_PATH:-/usr/lib/pkcs11/aws_kms_pkcs11.so}"
export PKCS11_MODULE_PATH
KMS_CA_CONFIG_HOME="${KMS_CA_CONFIG_HOME:-/tmp/kms-ca}"
ENGINE_OPTS=(-engine pkcs11 -keyform engine)

usage() {
  cat >&2 <<'EOF'
Usage: kms-ca.sh <command> [arguments]

  config                                           write the aws-kms-pkcs11 config from PKI_KMS_CA_KEYS
  csr           <label> <out.csr>                  CSR for the key behind <label> (subject from the naming rules)
  root-self-sign <root-label> <out.pem> <days>     self-signed Root CA certificate
  issue-ca      <issuer-label> <issuer.pem> <in.csr> <out.pem> <days> [pathlen]
                                                   CA certificate; issuer root -> Intermediate CA (pathlen 2, so it can
                                                   issue a bridged successor), issuer intermediate -> Enrollment Signing
                                                   CA (pathlen 0). Give [pathlen] 1 for a bridged Intermediate CA (#172)
  sign          <issuer-label> <issuer.pem> <in.csr> <out.pem> <days> <ext-section> <ext-file>
                                                   leaf certificate, same extension handling as makeCert.sh
                                                   (-extensions <ext-section> -extfile <ext-file>)
  crl           <label> <cert.pem> <out.crl> <days>
                                                   CRL signed by the key behind <label>

Labels look like root-ca-01 or intermediate-ca-02.
EOF
  exit 2
}

die() { echo "kms-ca.sh: $*" >&2; exit 1; }

TMP_DIR=""
cleanup() { [[ -n "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# Validation and naming
# ---------------------------------------------------------------------------------------------
validate_label() {
  [[ "$1" =~ ^(root|intermediate)-ca-[0-9]{2}$ ]] || die "invalid key label '$1' (expected root-ca-NN or intermediate-ca-NN)"
  [[ "${1: -2}" != "00" ]] || die "invalid key label '$1': the number starts at 01"
}

validate_days() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 36500 )) || die "invalid number of days '$1' (1-36500)"
}

validate_env_label() {
  [[ -n "${PKI_ENV_LABEL:-}" ]] || die "PKI_ENV_LABEL is not set"
  [[ "${PKI_ENV_LABEL}" =~ ^[A-Za-z0-9]([A-Za-z0-9\ -]{0,22}[A-Za-z0-9])?$ ]] \
    || die "invalid PKI_ENV_LABEL '${PKI_ENV_LABEL}' (1-24 letters, digits, spaces or hyphens)"
}

tier_of() { [[ "$1" == root-* ]] && echo root || echo intermediate; }

# Names only (no KMS key behind them): the Enrollment Signing CA has a software key, so it has a name
# but never a PKCS#11 token.
validate_name_label() {
  [[ "$1" =~ ^(root|intermediate|enrollment)-ca-[0-9]{2}$ ]] || die "invalid CA label '$1' (expected root-ca-NN, intermediate-ca-NN or enrollment-ca-NN)"
  [[ "${1: -2}" != "00" ]] || die "invalid CA label '$1': the number starts at 01"
}

# CN for a CA label, e.g. root-ca-01 -> "TAK.NZ Try Root CA 01", enrollment-ca-01 -> "TAK.NZ Try Enrollment CA 01"
common_name() {
  local label="$1" number name
  validate_name_label "${label}"
  validate_env_label
  number="${label: -2}"
  case "${label}" in
    root-*)         name="Root CA" ;;
    intermediate-*) name="Intermediate CA" ;;
    *)              name="Enrollment CA" ;;
  esac
  local cn="TAK.NZ ${PKI_ENV_LABEL} ${name} ${number}"
  (( ${#cn} <= 64 )) || die "common name '${cn}' is longer than 64 characters"
  echo "${cn}"
}

# Subject DN as passed to openssl -subj
subject_for() { echo "/O=TAK.NZ/CN=$(common_name "$1")"; }

# Positive 64-bit serial number (the top bit stays 0 so the DER integer is never negative)
random_serial() {
  local hex
  hex="$(openssl rand -hex 8)"
  printf '0x%x%s' $(( 0x${hex:0:1} & 7 )) "${hex:1}"
}

# ---------------------------------------------------------------------------------------------
# aws-kms-pkcs11 config
# ---------------------------------------------------------------------------------------------
cmd_config() {
  [[ "${KMS_CA_SKIP_CONFIG:-0}" == "1" ]] && return 0
  [[ -n "${PKI_KMS_CA_KEYS:-}" ]] || die "PKI_KMS_CA_KEYS is not set"
  local region="${PKI_KMS_REGION:-${AWS_REGION:-}}"
  [[ -n "${region}" ]] || die "PKI_KMS_REGION (or AWS_REGION) is not set"
  [[ "${region}" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "invalid Region '${region}'"

  local slots="[]" pair label key_id
  IFS=',' read -ra pairs <<< "${PKI_KMS_CA_KEYS}"
  for pair in "${pairs[@]}"; do
    [[ "${pair}" == *=* ]] || die "invalid entry '${pair}' in PKI_KMS_CA_KEYS (expected label=key-id)"
    label="${pair%%=*}"
    key_id="${pair#*=}"
    validate_label "${label}"
    [[ "${key_id}" =~ ^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|mrk-[0-9a-f]{32})$ ]] \
      || die "invalid KMS key id for '${label}'"
    slots="$(jq -c --arg l "${label}" --arg k "${key_id}" --arg r "${region}" \
      '. + [{label: $l, kms_key_id: $k, aws_region: $r}]' <<< "${slots}")"
  done

  local dir="${KMS_CA_CONFIG_HOME}/aws-kms-pkcs11"
  ( umask 077 && mkdir -p "${dir}" && jq -n --argjson s "${slots}" '{slots: $s}' > "${dir}/config.json" )
  export XDG_CONFIG_HOME="${KMS_CA_CONFIG_HOME}"
}

ensure_config() {
  cmd_config
  [[ -f "${PKCS11_MODULE_PATH}" ]] || die "PKCS#11 module not found: ${PKCS11_MODULE_PATH}"
}

# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------
cmd_csr() {
  [[ $# -eq 2 ]] || usage
  local label="$1" out="$2"
  validate_label "${label}"
  ensure_config
  openssl req -new "${ENGINE_OPTS[@]}" -key "pkcs11:token=${label}" -sha256 \
    -subj "$(subject_for "${label}")" -out "${out}" || { rm -f "${out}"; die "could not create a CSR with '${label}'"; }
  local check
  check="$(openssl req -in "${out}" -noout -verify 2>&1 || true)"
  [[ "${check}" == *"verify OK"* ]] || { rm -f "${out}"; die "CSR signature does not verify"; }
}

cmd_root_self_sign() {
  [[ $# -eq 3 ]] || usage
  local label="$1" out="$2" days="$3"
  validate_label "${label}"
  [[ "$(tier_of "${label}")" == root ]] || die "'${label}' is not a Root CA key"
  validate_days "${days}"
  ensure_config
  openssl req -x509 -new "${ENGINE_OPTS[@]}" -key "pkcs11:token=${label}" -sha256 -days "${days}" \
    -set_serial "$(random_serial)" -subj "$(subject_for "${label}")" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:3" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "${out}" || { rm -f "${out}"; die "could not self-sign with '${label}'"; }
  openssl verify -CAfile "${out}" "${out}" > /dev/null || { rm -f "${out}"; die "self-signed root does not verify"; }
}

# Common signing step. Verifies the result against the issuer certificate so that a mismatch
# between the KMS key and the issuer certificate never leaves a certificate behind.
sign_csr() {
  local issuer_label="$1" issuer_pem="$2" csr="$3" out="$4" days="$5" ext_section="$6" ext_file="$7"
  validate_label "${issuer_label}"
  validate_days "${days}"
  [[ -f "${issuer_pem}" ]] || die "issuer certificate not found: ${issuer_pem}"
  [[ -f "${csr}" ]] || die "CSR not found: ${csr}"
  [[ -f "${ext_file}" ]] || die "extension file not found: ${ext_file}"
  ensure_config
  if ! openssl x509 -req -sha256 -days "${days}" -in "${csr}" -CA "${issuer_pem}" \
    -CAkeyform engine -engine pkcs11 -CAkey "pkcs11:token=${issuer_label}" \
    -set_serial "$(random_serial)" -extensions "${ext_section}" -extfile "${ext_file}" -out "${out}"; then
    rm -f "${out}"
    die "could not sign with '${issuer_label}' and ${issuer_pem}: is '${issuer_label}' the key of that certificate?"
  fi
  if ! openssl verify -partial_chain -CAfile "${issuer_pem}" "${out}" > /dev/null 2>&1; then
    rm -f "${out}"
    die "the signed certificate does not verify against ${issuer_pem}: is '${issuer_label}' the key of that certificate?"
  fi
}

cmd_issue_ca() {
  [[ $# -eq 5 || $# -eq 6 ]] || usage
  local issuer_label="$1" issuer_pem="$2" csr="$3" out="$4" days="$5" pathlen
  validate_label "${issuer_label}"
  # Defaults leave room for the bridge of #172 (R -> S_old -> S_new(A) -> Cl -> client): the root allows
  # 3 CA certificates below it, an Intermediate CA issued by the root allows 2, a bridged one 1, an
  # Enrollment Signing CA 0. A strict validator rejects the bridged chain with smaller values.
  if [[ $# -eq 6 ]]; then
    pathlen="$6"
    [[ "${pathlen}" =~ ^[0-3]$ ]] || die "invalid pathlen '${pathlen}' (0-3)"
  elif [[ "$(tier_of "${issuer_label}")" == root ]]; then pathlen=2; else pathlen=0; fi
  TMP_DIR="$(mktemp -d)"
  cat > "${TMP_DIR}/ca_ext.cnf" <<EOF
[ca_ext]
basicConstraints=critical,CA:TRUE,pathlen:${pathlen}
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
  sign_csr "${issuer_label}" "${issuer_pem}" "${csr}" "${out}" "${days}" ca_ext "${TMP_DIR}/ca_ext.cnf"
}

cmd_sign() {
  [[ $# -eq 7 ]] || usage
  sign_csr "$@"
}

cmd_crl() {
  [[ $# -eq 4 ]] || usage
  local label="$1" cert="$2" out="$3" days="$4"
  validate_label "${label}"
  validate_days "${days}"
  [[ -f "${cert}" ]] || die "certificate not found: ${cert}"
  ensure_config
  TMP_DIR="$(mktemp -d)"
  : > "${TMP_DIR}/index.txt"
  printf '[ca]\ndefault_ca=ca_default\n[ca_default]\ndir=%s\ndatabase=%s/index.txt\ndefault_md=sha256\n' \
    "${TMP_DIR}" "${TMP_DIR}" > "${TMP_DIR}/crl.cnf"
  openssl ca -config "${TMP_DIR}/crl.cnf" -engine pkcs11 -keyform engine -keyfile "pkcs11:token=${label}" \
    -cert "${cert}" -gencrl -crldays "${days}" -out "${out}" || { rm -f "${out}"; die "could not sign a CRL with '${label}' and ${cert}"; }
  openssl crl -in "${out}" -noout -verify -CAfile "${cert}" > /dev/null 2>&1 || { rm -f "${out}"; die "CRL does not verify against ${cert}"; }
}

main() {
  [[ $# -ge 1 ]] || usage
  local command="$1"; shift
  case "${command}" in
    config)         cmd_config "$@" ;;
    csr)            cmd_csr "$@" ;;
    root-self-sign) cmd_root_self_sign "$@" ;;
    issue-ca)       cmd_issue_ca "$@" ;;
    sign)           cmd_sign "$@" ;;
    crl)            cmd_crl "$@" ;;
    common-name)    [[ $# -eq 1 ]] || usage; common_name "$1" ;;
    *)              usage ;;
  esac
}

# Allow sourcing for tests (KMS_CA_SOURCE_ONLY=1)
if [[ "${KMS_CA_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
