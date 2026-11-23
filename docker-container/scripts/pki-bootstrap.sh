#!/bin/bash
# pki-bootstrap.sh - first-boot PKI for new stacks (#189, architecture in #171).
#
# Builds the target hierarchy on the first start of a stack and restores the part that must not live
# on the EFS on every later start:
#
#   Root CA 01 (KMS) -> Intermediate CA 01 (KMS) -> Enrollment CA 01 (software key) -> admin cert
#                                                 -> server cert
#
# R and S are signed with the KMS keys through kms-ca.sh (#136). The Enrollment CA key is kept in
# Secrets Manager and only ever written to tmpfs; the file TAK Server reads on the EFS
# (intermediate-ca-signing.jks) is a symlink to it. This script does not renew or rotate anything
# (#131, #132, #135, #169, #171, #172).
#
# server-cert-rotate.sh (#131) sources this file with PKI_BOOTSTRAP_SOURCE_ONLY=1 for the settings and
# the helpers (load_settings, write_ext_file, jks_from_p12); `main` is not run then.
#
# Exit codes: 0 PKI ready (bootstrapped now, or restored), 2 not applicable (not configured, or this
# stack already has a PKI from the old flow), 1 error.
#
# Environment:
#   PKI_KMS_CA_KEYS          <label>=<kms key id> pairs (set by the CDK stack); empty = not applicable
#   PKI_ENV_LABEL            environment label in the CA names, e.g. "Try"
#   PKI_ENROLLMENT_CA_SECRET Secrets Manager secret (name or ARN) for the Enrollment CA keystore
#   PKI_SERVER_NAMES         comma separated DNS names of the server cert; the first one is the CN
#                            (for example ops.try.tak.nz,tak.try.tak.nz); "takserver" is always added
#   PKI_ROOT_DAYS (7300) PKI_INTERMEDIATE_DAYS (3650) PKI_ENROLLMENT_CA_DAYS (1095)
#   PKI_SERVER_CERT_DAYS (365) PKI_ADMIN_CERT_DAYS (365)
#   P12_PROFILE              compat3des (default) | aes256: PKCS#12 profile of user-facing p12 files (#133)
#   PKI_FILES_DIR (/opt/tak/certs/files) PKI_TMPFS_DIR (/dev/shm/tak-pki)
#   PKI_KMS_CA_SCRIPT (/opt/tak/scripts/kms-ca.sh)
set -euo pipefail

FILES_DIR="${PKI_FILES_DIR:-/opt/tak/certs/files}"
TMPFS_DIR="${PKI_TMPFS_DIR:-/dev/shm/tak-pki}"
KMS_CA="${PKI_KMS_CA_SCRIPT:-/opt/tak/scripts/kms-ca.sh}"
# The cluster lock (#7): with several nodes starting on a fresh stack, only one builds the PKI
export CLUSTER_LOCK_DIR="${CLUSTER_LOCK_DIR:-${FILES_DIR}/.locks}"
export CLUSTER_LOCK_WAIT="${CLUSTER_LOCK_WAIT:-600}"
# shellcheck source=cluster-lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/cluster-lock.sh"
# The keystore password CoreConfig.xml already uses for every keystore. It protects the JKS/PKCS#12
# files, not the CA keys (R and S are in KMS, the Enrollment CA key is in Secrets Manager).
KS_PASS="atakatak"
STATE_FILE="${FILES_DIR}/pki-state.json"
SIGNING_ALIAS="intermediate-ca"

log() { echo "TAK Server - PKI: $*"; }
die() { echo "TAK Server - PKI: ERROR: $*" >&2; exit 1; }

WORK=""
cleanup() {
  # the work directory holds files and the CRL directory tree (find -delete removes the directories after their files)
  [[ -n "${WORK}" && -d "${WORK}" ]] && { find "${WORK}" -delete 2> /dev/null || true; }
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------------------------
int_setting() { # name default
  local v="${!1:-$2}"
  [[ "${v}" =~ ^[0-9]{1,5}$ ]] && (( 10#${v} >= 1 )) || die "$1 must be a number of days, got '${v}'"
  echo "$(( 10#${v} ))"
}

load_settings() {
  [[ -n "${PKI_ENV_LABEL:-}" ]] || die "PKI_ENV_LABEL is not set"
  [[ -n "${PKI_ENROLLMENT_CA_SECRET:-}" ]] || die "PKI_ENROLLMENT_CA_SECRET is not set"
  [[ -n "${PKI_SERVER_NAMES:-}" ]] || die "PKI_SERVER_NAMES is not set"
  ROOT_DAYS="$(int_setting PKI_ROOT_DAYS 7300)"
  INTERMEDIATE_DAYS="$(int_setting PKI_INTERMEDIATE_DAYS 3650)"
  ENROLLMENT_DAYS="$(int_setting PKI_ENROLLMENT_CA_DAYS 1095)"
  SERVER_DAYS="$(int_setting PKI_SERVER_CERT_DAYS 365)"
  ADMIN_DAYS="$(int_setting PKI_ADMIN_CERT_DAYS 365)"
  # A certificate must not outlive its issuer
  (( ROOT_DAYS > INTERMEDIATE_DAYS && INTERMEDIATE_DAYS > ENROLLMENT_DAYS && ENROLLMENT_DAYS >= SERVER_DAYS && ENROLLMENT_DAYS >= ADMIN_DAYS )) \
    || die "validities must satisfy root > intermediate > enrollment CA >= server and admin (got ${ROOT_DAYS}/${INTERMEDIATE_DAYS}/${ENROLLMENT_DAYS}/${SERVER_DAYS}/${ADMIN_DAYS})"

  case "${P12_PROFILE:-compat3des}" in
    compat3des) P12_OPTS=(-legacy -descert) ;;
    aes256)     P12_OPTS=() ;;
    *) die "P12_PROFILE must be compat3des or aes256, got '${P12_PROFILE}'" ;;
  esac

  IFS=',' read -ra NAMES <<< "${PKI_SERVER_NAMES}"
  local n
  for n in "${NAMES[@]}"; do
    [[ "${n}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || die "invalid server name '${n}' in PKI_SERVER_NAMES"
  done
  SERVER_CN="${NAMES[0]}"
  SAN="DNS:takserver"
  for n in "${NAMES[@]}"; do SAN="${SAN},DNS:${n}"; done

  # A new stack starts with generation 01. A stack with a PKI takes its generations from the state file: after a rotation
  # (#171) an operator removes the old generation from the configuration, and every script must still start (#172).
  local slots=(root-ca-01 intermediate-ca-01)
  if [[ -f "${STATE_FILE}" ]]; then
    slots=("$(printf 'root-ca-%02d' "$(jq -r '.numbers.root // 1' "${STATE_FILE}")")" "$(printf 'intermediate-ca-%02d' "$(jq -r '.numbers.intermediate // 1' "${STATE_FILE}")")")
  fi
  for slot in "${slots[@]}"; do
    [[ ",${PKI_KMS_CA_KEYS}," == *",${slot}="* ]] || die "PKI_KMS_CA_KEYS has no ${slot}: $([[ -f "${STATE_FILE}" ]] && echo "it is the generation in use (${STATE_FILE})" || echo 'a new stack starts with generation 01')"
  done
  export PKI_ENV_LABEL
  ROOT_CN="$("${KMS_CA}" common-name root-ca-01)"
  INTERMEDIATE_CN="$("${KMS_CA}" common-name intermediate-ca-01)"
  ENROLLMENT_CN="$("${KMS_CA}" common-name enrollment-ca-01)"
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
positive_serial() {
  local hex
  hex="$(openssl rand -hex 8)"
  printf '0x%x%s' $(( 0x${hex:0:1} & 7 )) "${hex:1}"
}

# ext sections: server, client (same shape as TAK's config.cfg, plus key identifiers #169 needs)
write_ext_file() { # path
  cat > "$1" <<EOF
[ server ]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=critical,clientAuth,serverAuth
subjectAltName=${SAN}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
[ client ]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=critical,clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
}


jks_from_p12() { # p12 jks alias
  keytool -importkeystore -srckeystore "$1" -srcstoretype PKCS12 -srcstorepass "${KS_PASS}" \
    -destkeystore "$2" -deststoretype JKS -deststorepass "${KS_PASS}" -destkeypass "${KS_PASS}" -alias "$3" -noprompt > /dev/null 2>&1 \
    || die "could not build $2"
}


link_signing_keystore() { # dir with intermediate-ca-signing.{jks,p12}
  ln -sfn "${TMPFS_DIR}/intermediate-ca-signing.jks" "${FILES_DIR}/intermediate-ca-signing.jks"
  ln -sfn "${TMPFS_DIR}/intermediate-ca-signing.p12" "${FILES_DIR}/intermediate-ca-signing.p12"
}


# shellcheck source=pki-trust-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/pki-trust-lib.sh"
# shellcheck source=pki-crl-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/pki-crl-lib.sh"
# ---------------------------------------------------------------------------------------------
# Restore: the Enrollment CA keystore from Secrets Manager into tmpfs
# ---------------------------------------------------------------------------------------------
restore_signing_keystore() {
  log "restoring the Enrollment CA keystore from Secrets Manager into tmpfs"
  mkdir -p "${TMPFS_DIR}"
  chmod 700 "${TMPFS_DIR}"
  local b64 secret
  # the current generation: the secret that pki-rotate.sh recorded (a later Enrollment CA), else the one of the stack
  secret="$(signing_current_secret)"
  b64="$(aws secretsmanager get-secret-value --secret-id "${secret}" --query SecretBinary --output text 2> /dev/null)" \
    || die "cannot read secret ${secret} (state file exists, so the PKI is already bootstrapped)"
  [[ -n "${b64}" && "${b64}" != "None" ]] || die "secret ${secret} has no value"
  ( umask 077; echo "${b64}" | base64 -d > "${TMPFS_DIR}/intermediate-ca-signing.p12" )
  ( umask 077; rm -f "${TMPFS_DIR}/intermediate-ca-signing.jks"; jks_from_p12 "${TMPFS_DIR}/intermediate-ca-signing.p12" "${TMPFS_DIR}/intermediate-ca-signing.jks" "${SIGNING_ALIAS}" )
  chmod 644 "${TMPFS_DIR}/intermediate-ca-signing.jks"
  link_signing_keystore
}

# ---------------------------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------------------------
bootstrap() {
  log "no PKI yet: bootstrapping ${ROOT_CN} -> ${INTERMEDIATE_CN} -> ${ENROLLMENT_CN}"
  mkdir -p "${TMPFS_DIR}"
  chmod 700 "${TMPFS_DIR}"
  umask 077
  WORK="$(mktemp -d "${TMPFS_DIR}/work.XXXXXX")"
  cd "${WORK}"
  write_ext_file ext.cfg

  log "Root CA 01 and Intermediate CA 01 in KMS"
  "${KMS_CA}" root-self-sign root-ca-01 root-ca.pem "${ROOT_DAYS}" > /dev/null
  "${KMS_CA}" csr intermediate-ca-01 intermediate-ca.csr > /dev/null
  "${KMS_CA}" issue-ca root-ca-01 root-ca.pem intermediate-ca.csr intermediate-ca.pem "${INTERMEDIATE_DAYS}" > /dev/null

  log "Enrollment CA 01 (software key, kept in Secrets Manager and tmpfs only)"
  openssl genrsa -out enrollment-ca.key 2048 2> /dev/null
  openssl req -new -key enrollment-ca.key -subj "/O=TAK.NZ/CN=${ENROLLMENT_CN}" -out enrollment-ca.csr
  "${KMS_CA}" issue-ca intermediate-ca-01 intermediate-ca.pem enrollment-ca.csr enrollment-ca.pem "${ENROLLMENT_DAYS}" > /dev/null

  log "server certificate ${SERVER_CN} (${SAN})"
  openssl genrsa -out takserver.key 2048 2> /dev/null
  openssl req -new -key takserver.key -subj "/O=TAK.NZ/CN=${SERVER_CN}" -out takserver.csr
  "${KMS_CA}" sign intermediate-ca-01 intermediate-ca.pem takserver.csr takserver.pem "${SERVER_DAYS}" server ext.cfg > /dev/null

  log "admin certificate, signed by Enrollment CA 01"
  openssl genrsa -out admin.key.plain 2048 2> /dev/null
  openssl req -new -key admin.key.plain -subj "/O=TAK.NZ/CN=admin" -out admin.csr
  openssl x509 -req -sha256 -days "${ADMIN_DAYS}" -in admin.csr -CA enrollment-ca.pem -CAkey enrollment-ca.key \
    -set_serial "$(positive_serial)" -extensions client -extfile ext.cfg -out admin.cert.pem > /dev/null 2>&1 \
    || die "could not sign the admin certificate"

  log "checking the chains"
  openssl verify -CAfile root-ca.pem -untrusted <(cat intermediate-ca.pem) enrollment-ca.pem > /dev/null || die "Enrollment CA does not chain to the Root CA"
  openssl verify -CAfile root-ca.pem -untrusted intermediate-ca.pem takserver.pem > /dev/null || die "server certificate does not chain to the Root CA"
  openssl verify -CAfile root-ca.pem -untrusted <(cat intermediate-ca.pem enrollment-ca.pem) admin.cert.pem > /dev/null || die "admin certificate does not chain to the Root CA"

  log "keystores"
  cat intermediate-ca.pem root-ca.pem > s-r.pem
  cat enrollment-ca.pem intermediate-ca.pem root-ca.pem > cl-s-r.pem
  # Enrollment CA: p12 (AES, read by keytool) -> JKS; the p12 is what goes to Secrets Manager
  openssl pkcs12 -export -in enrollment-ca.pem -inkey enrollment-ca.key -certfile s-r.pem -name "${SIGNING_ALIAS}" \
    -out intermediate-ca-signing.p12 -passout "pass:${KS_PASS}"
  jks_from_p12 intermediate-ca-signing.p12 intermediate-ca-signing.jks "${SIGNING_ALIAS}"
  # Server: p12 in the configured profile, JKS for TAK Server
  openssl pkcs12 "${P12_OPTS[@]}" -export -in takserver.pem -inkey takserver.key -certfile s-r.pem -name takserver \
    -out takserver.p12 -passout "pass:${KS_PASS}"
  jks_from_p12 takserver.p12 takserver.jks takserver
  # Admin: p12 in the configured profile (read by TAKTeamManager and CloudTAK), PEM pair for the health check
  openssl pkcs12 "${P12_OPTS[@]}" -export -in admin.cert.pem -inkey admin.key.plain -certfile cl-s-r.pem -name admin \
    -out admin.p12 -passout "pass:${KS_PASS}"
  openssl rsa -in admin.key.plain -aes256 -out admin.key -passout "pass:${KS_PASS}" 2> /dev/null
  cat admin.cert.pem enrollment-ca.pem intermediate-ca.pem > admin.pem
  # Truststores, built from a manifest that goes into the state file (pki-trust-lib.sh): the server trusts R, S
  # and every Enrollment CA (ATAK sends only its leaf cert, #133), phones get S and R only (the Enrollment CA is
  # not in their store, #171, known limit)
  trust_default_manifest > trust-manifest.json
  trust_build trust-manifest.json "$(pwd)" "$(pwd)" || die "could not build the truststores"
  # An empty CRL for Enrollment CA 01 (#204): CoreConfig.xml lists it, and a revocation only has to add to it
  crl_create "$(pwd)/crl" enrollment-ca-01 "$(pwd)/enrollment-ca.pem" "$(pwd)/enrollment-ca.key" || die "could not create the CRL of Enrollment CA 01"
  log "storing the Enrollment CA keystore in Secrets Manager"
  aws secretsmanager put-secret-value --secret-id "${PKI_ENROLLMENT_CA_SECRET}" --secret-binary fileb://intermediate-ca-signing.p12 > /dev/null \
    || die "cannot write secret ${PKI_ENROLLMENT_CA_SECRET}; nothing was installed"

  log "installing the files"
  umask 022
  local f
  for f in root-ca.pem intermediate-ca.pem enrollment-ca.pem takserver.pem takserver.jks takserver.p12 admin.p12 admin.pem \
           truststore-intermediate-ca.jks truststore-intermediate-ca.p12 truststore-phone.jks truststore-phone.p12 fed-truststore.jks; do
    cp "${f}" "${FILES_DIR}/${f}"
  done
  mkdir -p "${FILES_DIR}/crl" && cp -R crl/. "${FILES_DIR}/crl/" || die "could not install the CRL"
  crl_combine > /dev/null || [[ $? == 10 ]] || die "could not write the combined CRL file"
  chmod -R a+rX "${FILES_DIR}/crl" || die "could not install the CRL"
  cp s-r.pem "${FILES_DIR}/enrollment-chain.pem" && chmod 644 "${FILES_DIR}/enrollment-chain.pem"   # the chain above Enrollment CA 01 (#172)
  cp intermediate-ca.pem "${FILES_DIR}/ca.pem"            # the issuing CA, as TAK's own flow names it (FederateCA secret)
  cp takserver.key "${FILES_DIR}/takserver.key"
  cp admin.key "${FILES_DIR}/admin.key"
  # cp keeps the 600 of the work files, so set the modes explicitly: certificates and truststores are
  # world-readable (as the TAK Server scripts leave them), keys and the p12 files with keys are not
  local pub
  for pub in root-ca.pem intermediate-ca.pem enrollment-ca.pem ca.pem takserver.pem admin.pem takserver.jks \
             truststore-intermediate-ca.jks truststore-intermediate-ca.p12 truststore-phone.jks truststore-phone.p12 fed-truststore.jks; do
    chmod 644 "${FILES_DIR}/${pub}"
  done
  chmod 600 "${FILES_DIR}/takserver.key" "${FILES_DIR}/admin.key" "${FILES_DIR}/admin.p12" "${FILES_DIR}/takserver.p12"
  # Signing keystore: tmpfs only, the EFS name is a symlink
  umask 077
  cp intermediate-ca-signing.p12 "${TMPFS_DIR}/intermediate-ca-signing.p12"
  cp intermediate-ca-signing.jks "${TMPFS_DIR}/intermediate-ca-signing.jks"
  chmod 644 "${TMPFS_DIR}/intermediate-ca-signing.jks"
  link_signing_keystore

  log "writing ${STATE_FILE}"
  nb() { openssl x509 -in "$1" -noout -enddate | cut -d= -f2; }
  jq -n \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg envLabel "${PKI_ENV_LABEL}" \
    --arg root "${ROOT_CN}" --arg inter "${INTERMEDIATE_CN}" --arg enr "${ENROLLMENT_CN}" --arg server "${SERVER_CN}" --arg san "${SAN}" \
    --arg rootEnd "$(nb root-ca.pem)" --arg interEnd "$(nb intermediate-ca.pem)" --arg enrEnd "$(nb enrollment-ca.pem)" \
    --arg serverEnd "$(nb takserver.pem)" --arg adminEnd "$(nb admin.cert.pem)" --arg profile "${P12_PROFILE:-compat3des}" \
    --argjson trust "$(jq -c '{entries: .entries}' trust-manifest.json)" \
    '{version: 1, created: $created, environmentLabel: $envLabel, p12Profile: $profile,
      names: {root: $root, intermediate: $inter, enrollment: $enr, serverCn: $server, serverSan: $san},
      numbers: {root: 1, intermediate: 1, enrollment: 1}, trust: $trust,
      notAfter: {root: $rootEnd, intermediate: $interEnd, enrollment: $enrEnd, server: $serverEnd, admin: $adminEnd}}' \
    > "${STATE_FILE}.new"
  mv "${STATE_FILE}.new" "${STATE_FILE}"
  chmod 644 "${STATE_FILE}"
  log "bootstrap done"
}

# ---------------------------------------------------------------------------------------------
# Runs under the cluster lock. A node that waited for the lock finds the state file of the node that
# built the PKI, and only restores. Everything that decides between "build", "restore" and "not
# applicable" is checked here, inside the lock: outside it, a node could see the ca.pem that another node
# has just written and take it for a PKI of the old flow.
NOT_APPLICABLE=0
run_locked() {
  if [[ ! -f "${STATE_FILE}" && -f "${FILES_DIR}/ca.pem" ]]; then
    log "this stack already has a PKI from the old flow (ca.pem exists, no ${STATE_FILE}): leaving it alone"
    NOT_APPLICABLE=1
    return 0
  fi
  if [[ -f "${STATE_FILE}" ]]; then
    local f
    for f in takserver.jks truststore-intermediate-ca.jks admin.pem admin.key ca.pem; do
      [[ -s "${FILES_DIR}/${f}" ]] || die "${FILES_DIR}/${f} is missing although ${STATE_FILE} exists; not generating a second PKI"
    done
    restore_signing_keystore
    enrollment_chain_file > /dev/null || die "cannot write ${FILES_DIR}/enrollment-chain.pem"
    # A PKI from before the CRLs gets an empty one for every Enrollment CA, before CoreConfig.xml is generated
    trust_ensure_manifest || die "cannot write the trust manifest"
    local crc=0
    crl_ensure_all || crc=$?
    # a missing CRL does not stop the start: revocation is not available for that CA until it is fixed
    (( crc == 0 || crc == 10 )) || log "WARNING: not every Enrollment CA has a CRL (see above); revoke-cert.sh cannot revoke for the others"
    log "PKI ready (restored)"
  else
    bootstrap
    log "PKI ready (bootstrapped)"
  fi
}
# ---------------------------------------------------------------------------------------------
main() {
  if [[ -z "${PKI_KMS_CA_KEYS:-}" ]]; then
    log "not configured (PKI_KMS_CA_KEYS is empty): using the TAK Server certificate scripts"
    exit 2
  fi
  mkdir -p "${FILES_DIR}"
  load_settings
  # Not `with_cluster_lock ... || ...`: run_locked relies on set -e. A failure ends this script, and the
  # heartbeat of the lock releases it.
  with_cluster_lock pki-bootstrap run_locked
  [[ "${NOT_APPLICABLE}" -eq 0 ]] || exit 2
}
if [[ "${PKI_BOOTSTRAP_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
