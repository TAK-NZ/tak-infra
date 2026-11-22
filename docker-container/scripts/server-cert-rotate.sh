#!/bin/bash
# server-cert-rotate.sh - automated TAK Server TLS certificate rotation (#131, architecture in #171).
#
#   server-cert-rotate.sh check    rotate when the server certificate has PKI_SERVER_CERT_RENEW_DAYS (60) or
#                                  fewer days left; this is what the daily loop in start-tak.sh runs
#   server-cert-rotate.sh rotate   rotate now, whatever the expiry (manual run, test)
#
# Applies to stacks with the first-boot PKI of pki-bootstrap.sh (a state file exists). Anything else exits
# 0 without doing anything: a stack with the PKI of the TAK Server scripts keeps its behaviour.
#
# Rotation, under the cluster lock `server-cert-rotation` (#7), so that only one node does it:
#  1. A new key and CSR for the same names as the current certificate (PKI_SERVER_NAMES), signed by
#     Intermediate CA S in KMS (kms-ca.sh, #136). Validity PKI_SERVER_CERT_DAYS.
#  2. Everything is built and checked in tmpfs first: the chain against R and S, the key against the
#     certificate, CN and SAN, the days left, and that the new takserver.jks and takserver.p12 open and
#     hold the new certificate. Nothing on the EFS changes if a check fails.
#  3. The four files (takserver.pem, .key, .p12, .jks) are swapped in: a marker file first, then a
#     `.prev` copy of each, then one atomic rename per file, then the same checks on the installed files.
#     A failure restores the `.prev` copies. A marker that is still there at the next run means the swap
#     was interrupted (task stopped): the `.prev` copies are restored then.
#  4. The state file is updated, TakServerCertRotated is emitted, and an ECS rolling deployment makes every
#     node load the new keystore. Phones are not touched: they do not pin the leaf (#171).
# Every failure emits TakServerCertRotationFailed (alarm and SNS alert from #129).
#
# Environment: the settings of pki-bootstrap.sh, plus
#   PKI_SERVER_CERT_RENEW_DAYS (60)  must be smaller than PKI_SERVER_CERT_DAYS, or a new certificate would
#                                    be rotated again at once
#   ECS_Cluster_Name, ECS_Service_Name  for the rolling deployment (skipped when SERVER_CERT_ROTATE_NO_DEPLOY=1)
#   SERVER_CERT_ROTATE_BREAK_INSTALL=1  test only: damage the installed keystore, to exercise the rollback
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_BOOTSTRAP_SOURCE_ONLY=1
# shellcheck source=pki-bootstrap.sh
source "${SCRIPT_DIR}/pki-bootstrap.sh"
CERT_FILES=(takserver.pem takserver.key takserver.p12 takserver.jks)
MARKER="${FILES_DIR}/.takserver-rotation.pending"
METRICS="${SCRIPT_DIR}/cert-metrics.sh"
LOCK_NAME="server-cert-rotation"

emit() { "${METRICS}" emit "$1" 1 || true; }
days_left() { # pem -> whole days until notAfter (negative when expired)
  local end
  end="$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" || return 1
  echo $(( ($(date -d "${end}" +%s) - $(date +%s)) / 86400 ))
}
pub_of_cert() { openssl x509 -in "$1" -noout -pubkey 2> /dev/null | openssl sha256 2> /dev/null; }
pub_of_key() { openssl pkey -in "$1" -pubout 2> /dev/null | openssl sha256 2> /dev/null; }
fp_of_cert() { openssl x509 -in "$1" -noout -fingerprint -sha256 2> /dev/null; }
fp_of_jks() { # jks -> fingerprint of the takserver entry
  keytool -exportcert -alias takserver -keystore "$1" -storepass "${KS_PASS}" -rfc 2> /dev/null | openssl x509 -noout -fingerprint -sha256 2> /dev/null
}
mode_of() { case "$1" in takserver.key | takserver.p12) echo 600 ;; *) echo 644 ;; esac; }

# Checks that hold for a set of files in a directory: used on the new files in tmpfs and again on the
# installed files. Prints the reason and returns 1.
check_set() { # dir
  local d="$1" fp
  [[ -s "${d}/takserver.pem" && -s "${d}/takserver.key" && -s "${d}/takserver.jks" && -s "${d}/takserver.p12" ]] \
    || { log "check: a file is missing or empty in ${d}"; return 1; }
  [[ -n "$(pub_of_cert "${d}/takserver.pem")" && "$(pub_of_cert "${d}/takserver.pem")" == "$(pub_of_key "${d}/takserver.key")" ]] \
    || { log "check: the key does not match the certificate"; return 1; }
  openssl verify -CAfile "${FILES_DIR}/root-ca.pem" -untrusted "${FILES_DIR}/intermediate-ca.pem" "${d}/takserver.pem" > /dev/null 2>&1 \
    || { log "check: the certificate does not chain to the Intermediate CA and Root CA"; return 1; }
  fp="$(fp_of_cert "${d}/takserver.pem")"
  [[ -n "${fp}" && "$(fp_of_jks "${d}/takserver.jks")" == "${fp}" ]] \
    || { log "check: takserver.jks does not open with the keystore password or holds another certificate"; return 1; }
  openssl pkcs12 -in "${d}/takserver.p12" -passin "pass:${KS_PASS}" -nokeys -clcerts 2> /dev/null | openssl x509 -noout -fingerprint -sha256 2> /dev/null | grep -qxF "${fp}" \
    || { log "check: takserver.p12 does not open with the keystore password or holds another certificate"; return 1; }
  keytool -list -keystore "${d}/takserver.jks" -storepass "${KS_PASS}" 2> /dev/null | grep -q "PrivateKeyEntry" \
    || { log "check: takserver.jks has no private key entry"; return 1; }
  return 0
}

# New key and certificate, built and checked in tmpfs. Returns 1 with a reason in the log.
build_new() {
  local slot ext
  slot="intermediate-ca-$(printf '%02d' "$(jq -r '.numbers.intermediate' "${STATE_FILE}")")"
  umask 077
  write_ext_file ext.cfg
  log "new server certificate ${SERVER_CN} (${SAN}), signed by ${slot}"
  openssl genrsa -out takserver.key 2048 2> /dev/null || { log "could not generate the key"; return 1; }
  openssl req -new -key takserver.key -subj "/O=TAK.NZ/CN=${SERVER_CN}" -out takserver.csr || { log "could not build the CSR"; return 1; }
  "${KMS_CA}" sign "${slot}" "${FILES_DIR}/intermediate-ca.pem" takserver.csr takserver.pem "${SERVER_DAYS}" server ext.cfg > /dev/null \
    || { log "KMS signing failed"; return 1; }
  # CN and SAN as configured
  [[ "$(openssl x509 -in takserver.pem -noout -subject -nameopt RFC2253 2> /dev/null)" == "subject=CN=${SERVER_CN},O=TAK.NZ" ]] \
    || { log "check: the subject of the new certificate is not CN=${SERVER_CN},O=TAK.NZ"; return 1; }
  ext="$(openssl x509 -in takserver.pem -noout -ext subjectAltName 2> /dev/null)" || { log "check: the new certificate has no SAN"; return 1; }
  local n
  for n in takserver "${NAMES[@]}"; do
    [[ "${ext}" == *"DNS:${n}"* ]] || { log "check: DNS:${n} is not in the SAN of the new certificate"; return 1; }
  done
  local left
  left="$(days_left takserver.pem)" || { log "could not read the new certificate"; return 1; }
  (( left > RENEW_DAYS )) || { log "check: the new certificate has ${left} days left, not more than the renewal threshold of ${RENEW_DAYS}: it would be replaced at once"; return 1; }
  cat "${FILES_DIR}/intermediate-ca.pem" "${FILES_DIR}/root-ca.pem" > s-r.pem
  openssl pkcs12 "${P12_OPTS[@]}" -export -in takserver.pem -inkey takserver.key -certfile s-r.pem -name takserver \
    -out takserver.p12 -passout "pass:${KS_PASS}" 2> /dev/null || { log "could not build takserver.p12"; return 1; }
  jks_from_p12 takserver.p12 takserver.jks takserver || return 1
  check_set "${WORK}"
}

restore_previous() { # puts the .prev copies back; returns 1 if one is missing
  local f ok=0
  for f in "${CERT_FILES[@]}"; do
    if [[ -s "${FILES_DIR}/${f}.prev" ]]; then
      cp -p "${FILES_DIR}/${f}.prev" "${FILES_DIR}/${f}.restore" && mv -f "${FILES_DIR}/${f}.restore" "${FILES_DIR}/${f}" || ok=1
    else
      log "no ${f}.prev to restore"; ok=1
    fi
  done
  return "${ok}"
}

# A marker means the swap of an earlier run did not finish.
recover_interrupted() {
  [[ -f "${MARKER}" ]] || return 0
  log "WARNING: the swap of an earlier rotation was interrupted (${MARKER}): restoring the previous files"
  emit TakServerCertRotationFailed
  if restore_previous && check_set "${FILES_DIR}"; then
    find "${MARKER}" -delete
    log "the previous server certificate is back in place"
    return 0
  fi
  log "ERROR: could not restore the previous files; the marker stays and nothing is rotated until that is fixed"
  return 1
}

install_new() {
  local f
  printf '{"started":"%s","previousNotAfter":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(openssl x509 -in "${FILES_DIR}/takserver.pem" -noout -enddate | cut -d= -f2)" > "${MARKER}" \
    || { log "cannot write ${MARKER}"; return 1; }
  for f in "${CERT_FILES[@]}"; do
    cp -p "${FILES_DIR}/${f}" "${FILES_DIR}/${f}.prev" || { log "cannot copy ${f} to ${f}.prev"; return 1; }
  done
  for f in "${CERT_FILES[@]}"; do
    cp "${WORK}/${f}" "${FILES_DIR}/${f}.new" && chmod "$(mode_of "${f}")" "${FILES_DIR}/${f}.new" && mv -f "${FILES_DIR}/${f}.new" "${FILES_DIR}/${f}" \
      || { log "cannot install ${f}"; return 1; }
  done
  if [[ "${SERVER_CERT_ROTATE_BREAK_INSTALL:-0}" == "1" ]]; then echo "broken" > "${FILES_DIR}/takserver.jks"; fi
  check_set "${FILES_DIR}" || return 1
  return 0
}

update_state() {
  jq --arg notAfter "$(openssl x509 -in "${FILES_DIR}/takserver.pem" -noout -enddate | cut -d= -f2)" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.notAfter.server = $notAfter | .serverCertRotatedAt = $at' "${STATE_FILE}" > "${STATE_FILE}.new" \
    && chmod 644 "${STATE_FILE}.new" && mv -f "${STATE_FILE}.new" "${STATE_FILE}"
}

trigger_deployment() { # a rolling deployment makes every node load the new keystore
  if [[ "${SERVER_CERT_ROTATE_NO_DEPLOY:-0}" == "1" ]]; then log "deployment skipped (SERVER_CERT_ROTATE_NO_DEPLOY=1)"; return 0; fi
  if [[ -z "${ECS_Cluster_Name:-}" || -z "${ECS_Service_Name:-}" ]]; then log "ECS_Cluster_Name or ECS_Service_Name is not set"; return 1; fi
  local i
  for i in 1 2 3; do
    if aws ecs update-service --cluster "${ECS_Cluster_Name}" --service "${ECS_Service_Name}" --force-new-deployment > /dev/null 2>&1; then
      log "rolling deployment started: every node loads the new certificate"
      return 0
    fi
    sleep "${SERVER_CERT_ROTATE_RETRY_DELAY:-5}"
  done
  return 1
}

# The status of this function is the status of the script. It runs with `set -e` off (the caller needs its
# status), so every step checks its own result.
rotate_locked() { # [force]
  recover_interrupted || return 1
  local left
  left="$(days_left "${FILES_DIR}/takserver.pem")" || { log "ERROR: cannot read ${FILES_DIR}/takserver.pem"; emit TakServerCertRotationFailed; return 1; }
  if [[ "${1:-}" != "force" ]] && (( left > RENEW_DAYS )); then
    log "the server certificate has ${left} days left (renewal at ${RENEW_DAYS} or fewer): nothing to do"
    return 0
  fi
  log "rotating the server certificate (${left} days left)"
  umask 077
  mkdir -p "${TMPFS_DIR}"
  chmod 700 "${TMPFS_DIR}"
  WORK="$(mktemp -d "${TMPFS_DIR}/rotate.XXXXXX")" && cd "${WORK}" \
    || { WORK=""; log "ERROR: cannot make a work directory in ${TMPFS_DIR}"; emit TakServerCertRotationFailed; return 1; }
  if ! build_new; then
    log "ERROR: the new certificate was not accepted; nothing was installed"
    emit TakServerCertRotationFailed
    return 1
  fi
  if ! install_new; then
    log "ERROR: installing the new certificate failed; restoring the previous files"
    if restore_previous && check_set "${FILES_DIR}"; then
      find "${MARKER}" -delete
      log "the previous server certificate is back in place"
    else
      log "ERROR: could not restore the previous files; the marker stays and the next run tries again"
    fi
    emit TakServerCertRotationFailed
    return 1
  fi
  find "${MARKER}" -delete
  update_state || log "WARNING: could not update ${STATE_FILE}"
  log "server certificate rotated: new notAfter $(openssl x509 -in "${FILES_DIR}/takserver.pem" -noout -enddate | cut -d= -f2)"
  emit TakServerCertRotated
  if ! trigger_deployment; then
    log "ERROR: the rolling deployment could not be started: the new certificate is installed, but TAK Server loads it only at its next restart"
    emit TakServerCertRotationFailed
    return 1
  fi
  return 0
}

main() {
  local cmd="${1:-}"
  [[ "${cmd}" == "check" || "${cmd}" == "rotate" ]] || { echo "usage: ${0##*/} check|rotate" >&2; exit 64; }
  if [[ -z "${PKI_KMS_CA_KEYS:-}" || ! -f "${STATE_FILE}" ]]; then
    log "server certificate rotation: not applicable (no first-boot PKI on this stack)"
    exit 0
  fi
  load_settings
  RENEW_DAYS="$(int_setting PKI_SERVER_CERT_RENEW_DAYS 60)"
  (( RENEW_DAYS < SERVER_DAYS )) || die "PKI_SERVER_CERT_RENEW_DAYS (${RENEW_DAYS}) must be smaller than PKI_SERVER_CERT_DAYS (${SERVER_DAYS})"
  # From here a failure is reported by the functions, not by exiting
  die() { log "ERROR: $*"; return 1; }
  if [[ "${cmd}" == "check" && ! -f "${MARKER}" ]]; then
    local left
    left="$(days_left "${FILES_DIR}/takserver.pem")" || { log "ERROR: cannot read ${FILES_DIR}/takserver.pem"; emit TakServerCertRotationFailed; exit 1; }
    if (( left > RENEW_DAYS )); then
      log "server certificate: ${left} days left (renewal at ${RENEW_DAYS} or fewer)"
      exit 0
    fi
  fi
  CLUSTER_LOCK_WAIT="${CLUSTER_LOCK_WAIT:-900}"
  local rc=0 force=""
  [[ "${cmd}" == "rotate" ]] && force="force"
  with_cluster_lock "${LOCK_NAME}" rotate_locked ${force} || rc=$?
  exit "${rc}"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
