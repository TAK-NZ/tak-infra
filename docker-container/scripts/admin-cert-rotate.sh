#!/bin/bash
# admin-cert-rotate.sh - automated rotation of the TAK Server admin client certificate (#132, #171).
#
#   admin-cert-rotate.sh check    housekeeping, then rotate when the admin certificate has
#                                 PKI_ADMIN_CERT_RENEW_DAYS (60) or fewer days left; the daily loop in
#                                 start-tak.sh runs this
#   admin-cert-rotate.sh rotate   rotate now, whatever the expiry
#
# Applies to stacks with the first-boot PKI of pki-bootstrap.sh (a state file exists); anything else exits 0.
#
# Who uses the admin certificate: the container health check (admin.pem and admin.key), the admin user
# elevation at start (`UserManager.jar certmod -A admin.pem`), and every service that reads admin.p12 from
# the secret <StackName>/TAK-Server/Admin-Cert (TAKTeamManager, CloudTAK, ...).
#
# Rotation, under the cluster lock `admin-cert-rotation` (#7):
#  1. A new key and CSR for CN=admin, signed by the Enrollment CA (Cl). Its key is the software key that
#     start-tak.sh restores from Secrets Manager into tmpfs; it never touches the EFS.
#  2. Built and checked in tmpfs: chain to R, S and Cl, key against certificate, CN, days left, and that
#     admin.p12 and admin.key open with the keystore password.
#  3. Registered with TAK Server BEFORE any file changes (`UserManager.jar certmod -A`), and used once against
#     the TAK Server API (certadmin) to prove that the server accepts it as administrator. A failure here
#     changes nothing on the EFS.
#  4. Swap of admin.pem, admin.key and admin.p12: a marker, `.prev` copies, one atomic rename per file, the
#     same checks on the installed files. A failure restores the `.prev` copies and registers the old
#     certificate again. A marker found at the next run means an interrupted swap and is handled the same way.
#  5. The secret is updated (put-secret-value, with the hash of the file as request token, as start-tak.sh
#     does). A failure is reported, the new files stay, and the next run tries the secret again.
#  6. pki-state.json is updated and AdminCertRotated is emitted. No restart is needed: the health check reads
#     the files on every call, and TAK Server looks the user up when a request arrives.
# Every failure emits AdminCertRotationFailed (alarm and SNS alert from #129); a rotation emits AdminCertRotated.
#
# The `.prev` copies hold the old admin key. They are deleted PKI_ADMIN_CERT_GRACE_DAYS (7) after the rotation:
# that is the window in which a rollback is possible and in which the services pick up the new secret
# (TAKTeamManager refreshes it every 24 hours).
#
# What this does NOT do: revoke the old certificate. TAK Server finds the admin user by the CN `admin` of any
# certificate that its truststore accepts, so the old certificate keeps working until its own notAfter, and
# TAK Server has no CRL configured here. The certadmin revoke API only knows certificates that TAK Server
# issued itself, which the admin certificate is not. The old certificate stops working when its issuer is
# removed from the truststore (an Enrollment CA rotation, #135) or when it expires.
#
# Environment: the settings of pki-bootstrap.sh, plus PKI_ADMIN_CERT_RENEW_DAYS (60, smaller than
# PKI_ADMIN_CERT_DAYS), PKI_ADMIN_CERT_GRACE_DAYS (7), StackName (for the secret), JAVA_BIN (java),
# TAK_USER_MANAGER_JAR (/opt/tak/utils/UserManager.jar), CURL_BIN (curl), ADMIN_CERT_ROTATE_API_URL
# (https://localhost:8443/Marti/api/certadmin/cert), ADMIN_CERT_ROTATE_BREAK_INSTALL=1 (test only).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_BOOTSTRAP_SOURCE_ONLY=1
# shellcheck source=pki-bootstrap.sh
source "${SCRIPT_DIR}/pki-bootstrap.sh"
# shellcheck source=pki-rotate-common.sh
source "${SCRIPT_DIR}/pki-rotate-common.sh"
CERT_FILES=(admin.pem admin.key admin.p12)
MARKER="${FILES_DIR}/.admin-rotation.pending"
LOCK_NAME="admin-cert-rotation"
JAVA="${JAVA_BIN:-java}"
USER_MANAGER="${TAK_USER_MANAGER_JAR:-/opt/tak/utils/UserManager.jar}"
CURL="${CURL_BIN:-curl}"
API_URL="${ADMIN_CERT_ROTATE_API_URL:-https://localhost:8443/Marti/api/certadmin/cert}"

emit_failed() { "${METRICS}" emit AdminCertRotationFailed 1 || true; }
mode_of() { case "$1" in admin.pem) echo 644 ;; *) echo 600 ;; esac; }
cert_of_pem() { # admin.pem (cert + chain) -> the first certificate
  openssl x509 -in "$1" 2> /dev/null
}
# `UserManager.jar` starts an embedded Ignite node that writes its work directory into the current
# directory: always run it from a throw-away directory
user_manager() { # args...
  local d rc=0
  d="$(mktemp -d "${TMPFS_DIR}/um.XXXXXX")" || return 1
  ( cd "${d}" && "${JAVA}" -jar "${USER_MANAGER}" "$@" ) || rc=$?
  find "${d}" -delete 2> /dev/null
  return "${rc}"
}
register_admin() { # pem: makes TAK Server know this certificate as administrator
  user_manager certmod -A "$1" > /dev/null 2>&1 || { log "certmod -A $1 failed"; return 1; }
}
check_registered() { # pem: TAK Server lists it as ROLE_ADMIN with this fingerprint
  local out fp
  out="$(user_manager certmod -s "$1" 2> /dev/null)" || { log "certmod -s failed"; return 1; }
  fp="$(openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2)"
  [[ "${out}" == *ROLE_ADMIN* && "${out}" == *"${fp}"* ]] || { log "check: TAK Server does not list the certificate as administrator with fingerprint ${fp}"; return 1; }
}
# One call that only an administrator may make, with the given certificate
api_accepts() { # pem key [passphrase]
  local code
  code="$("${CURL}" -sk --cert "$1" --key "$2" ${3:+--pass "$3"} -o /dev/null -w '%{http_code}' --max-time 30 "${API_URL}" 2> /dev/null)" || code="000"
  [[ "${code}" == "200" ]] || { log "check: the TAK Server API answered ${code} to the new certificate, not 200"; return 1; }
}

# Checks on a set of files in a directory, used on the new files in tmpfs and again on the installed ones
check_set() { # dir
  local d="$1" fp
  [[ -s "${d}/admin.pem" && -s "${d}/admin.key" && -s "${d}/admin.p12" ]] || { log "check: a file is missing or empty in ${d}"; return 1; }
  openssl rsa -in "${d}/admin.key" -passin "pass:${KS_PASS}" -check -noout > /dev/null 2>&1 || { log "check: admin.key does not open with the keystore password"; return 1; }
  [[ -n "$(pub_of_cert "${d}/admin.pem")" && "$(pub_of_cert "${d}/admin.pem")" == "$(openssl pkey -in "${d}/admin.key" -passin "pass:${KS_PASS}" -pubout 2> /dev/null | openssl sha256 2> /dev/null)" ]] \
    || { log "check: admin.key does not match admin.pem"; return 1; }
  openssl verify -CAfile "${FILES_DIR}/root-ca.pem" -untrusted <(cat "${FILES_DIR}/intermediate-ca.pem" "${FILES_DIR}/enrollment-ca.pem") "${d}/admin.pem" > /dev/null 2>&1 \
    || { log "check: the certificate does not chain to Enrollment CA, Intermediate CA and Root CA"; return 1; }
  [[ "$(openssl x509 -in "${d}/admin.pem" -noout -subject -nameopt RFC2253 2> /dev/null)" == "subject=CN=admin,O=TAK.NZ" ]] || { log "check: the subject is not CN=admin,O=TAK.NZ"; return 1; }
  fp="$(fp_of_cert "${d}/admin.pem")"
  openssl pkcs12 -in "${d}/admin.p12" -passin "pass:${KS_PASS}" -nokeys -clcerts 2> /dev/null | openssl x509 -noout -fingerprint -sha256 2> /dev/null | grep -qxF "${fp}" \
    || { log "check: admin.p12 does not open with the keystore password (without the legacy provider) or holds another certificate"; return 1; }
  [[ "$(openssl pkcs12 -in "${d}/admin.p12" -passin "pass:${KS_PASS}" -nocerts -nodes 2> /dev/null | openssl pkey -pubout 2> /dev/null | openssl sha256 2> /dev/null)" == "$(pub_of_cert "${d}/admin.pem")" ]] \
    || { log "check: admin.p12 holds another key"; return 1; }
  return 0
}

build_new() {
  local signer="${TMPFS_DIR}/intermediate-ca-signing.p12"
  umask 077
  [[ -s "${signer}" ]] || { log "the Enrollment CA keystore ${signer} is not there (it is restored from Secrets Manager at start)"; return 1; }
  openssl pkcs12 -in "${signer}" -passin "pass:${KS_PASS}" -nodes -nocerts -out enrollment-ca.key 2> /dev/null || { log "cannot read the Enrollment CA key"; return 1; }
  [[ "$(pub_of_key enrollment-ca.key)" == "$(pub_of_cert "${FILES_DIR}/enrollment-ca.pem")" ]] || { log "the Enrollment CA key does not match ${FILES_DIR}/enrollment-ca.pem"; return 1; }
  write_ext_file ext.cfg
  log "new admin certificate, signed by the Enrollment CA"
  openssl genrsa -out admin.key.plain 2048 2> /dev/null || { log "could not generate the key"; return 1; }
  openssl req -new -key admin.key.plain -subj "/O=TAK.NZ/CN=admin" -out admin.csr || { log "could not build the CSR"; return 1; }
  # The certificate must not outlive its issuer: capped to what the Enrollment CA has left
  local days="${ADMIN_DAYS}" cl_left
  cl_left="$(days_left "${FILES_DIR}/enrollment-ca.pem")" || { log "could not read enrollment-ca.pem"; return 1; }
  if (( cl_left - 1 < days )); then
    days=$(( cl_left - 1 ))
    log "the Enrollment CA has ${cl_left} days left: the new certificate gets ${days} days, not ${ADMIN_DAYS}"
  fi
  (( days > RENEW_DAYS )) || { log "check: the Enrollment CA has only ${cl_left} days left, not enough for a certificate that outlasts the renewal threshold of ${RENEW_DAYS} days: rotate the Enrollment CA first (#135)"; return 1; }
  openssl x509 -req -sha256 -days "${days}" -in admin.csr -CA "${FILES_DIR}/enrollment-ca.pem" -CAkey enrollment-ca.key \
    -set_serial "$(positive_serial)" -extensions client -extfile ext.cfg -out admin.cert.pem > /dev/null 2>&1 || { log "could not sign the new certificate"; return 1; }
  cat "${FILES_DIR}/enrollment-ca.pem" "${FILES_DIR}/intermediate-ca.pem" "${FILES_DIR}/root-ca.pem" > cl-s-r.pem
  cat admin.cert.pem "${FILES_DIR}/enrollment-ca.pem" "${FILES_DIR}/intermediate-ca.pem" > admin.pem
  openssl rsa -in admin.key.plain -aes256 -out admin.key -passout "pass:${KS_PASS}" 2> /dev/null || { log "could not write admin.key"; return 1; }
  openssl pkcs12 "${P12_OPTS[@]}" -export -in admin.cert.pem -inkey admin.key.plain -certfile cl-s-r.pem -name admin \
    -out admin.p12 -passout "pass:${KS_PASS}" 2> /dev/null || { log "could not build admin.p12"; return 1; }
  check_set "${WORK}"
}

restore_previous() { # puts the .prev copies back, and registers the old certificate again
  local f ok=0
  for f in "${CERT_FILES[@]}"; do
    if [[ -s "${FILES_DIR}/${f}.prev" ]]; then
      cp -p "${FILES_DIR}/${f}.prev" "${FILES_DIR}/${f}.restore" && mv -f "${FILES_DIR}/${f}.restore" "${FILES_DIR}/${f}" || ok=1
    else
      log "no ${f}.prev to restore"; ok=1
    fi
  done
  (( ok == 0 )) && { register_admin "${FILES_DIR}/admin.pem" || log "WARNING: could not register the old certificate again; the next start does it"; }
  return "${ok}"
}

recover_interrupted() {
  [[ -f "${MARKER}" ]] || return 0
  log "WARNING: the swap of an earlier rotation was interrupted (${MARKER}): restoring the previous files"
  emit_failed
  if restore_previous && check_set "${FILES_DIR}"; then
    find "${MARKER}" -delete
    log "the previous admin certificate is back in place"
    return 0
  fi
  log "ERROR: could not restore the previous files; the marker stays and nothing is rotated until that is fixed"
  return 1
}

install_new() {
  local f
  printf '{"started":"%s","previousNotAfter":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(openssl x509 -in "${FILES_DIR}/admin.pem" -noout -enddate | cut -d= -f2)" > "${MARKER}" \
    || { log "cannot write ${MARKER}"; return 1; }
  for f in "${CERT_FILES[@]}"; do
    cp -p "${FILES_DIR}/${f}" "${FILES_DIR}/${f}.prev" || { log "cannot copy ${f} to ${f}.prev"; return 1; }
  done
  for f in "${CERT_FILES[@]}"; do
    cp "${WORK}/${f}" "${FILES_DIR}/${f}.new" && chmod "$(mode_of "${f}")" "${FILES_DIR}/${f}.new" && mv -f "${FILES_DIR}/${f}.new" "${FILES_DIR}/${f}" \
      || { log "cannot install ${f}"; return 1; }
  done
  if [[ "${ADMIN_CERT_ROTATE_BREAK_INSTALL:-0}" == "1" ]]; then echo "broken" > "${FILES_DIR}/admin.p12"; fi
  check_set "${FILES_DIR}" || return 1
  return 0
}

state_set() { # jq filter and arguments: updates the state file
  jq "$@" "${STATE_FILE}" > "${STATE_FILE}.new" && chmod 644 "${STATE_FILE}.new" && mv -f "${STATE_FILE}.new" "${STATE_FILE}"
}

# The secret holds admin.p12. The request token is the hash of the file, as in start-tak.sh, so that the next
# start finds "unchanged".
update_secret() {
  local token err
  [[ -n "${StackName:-}" ]] || { log "StackName is not set: cannot name the secret"; return 1; }
  token="$(sha256sum "${FILES_DIR}/admin.p12" | cut -d' ' -f1)"
  err="$(aws secretsmanager put-secret-value --secret-id "${StackName}/TAK-Server/Admin-Cert" --secret-binary "fileb://${FILES_DIR}/admin.p12" \
          --client-request-token "${token}" 2>&1 > /dev/null)" && { log "the secret ${StackName}/TAK-Server/Admin-Cert is updated"; return 0; }
  [[ "${err}" == *ClientRequestTokenConflictException* ]] && { log "the secret already holds this file"; return 0; }
  log "could not update the secret: ${err:0:300}"
  return 1
}

# Work that does not depend on the expiry: a secret that could not be updated, and the old key copies.
maintenance() {
  if [[ "$(jq -r '.adminSecretPending // false' "${STATE_FILE}")" == "true" ]]; then
    log "the secret was not updated after the last rotation: trying again"
    if update_secret; then
      state_set 'del(.adminSecretPending)' || log "WARNING: could not update ${STATE_FILE}"
    else
      emit_failed
    fi
  fi
  local after
  after="$(jq -r '.adminPreviousRemoveAfter // empty' "${STATE_FILE}")"
  if [[ -n "${after}" ]] && (( $(date +%s) >= $(date -d "${after}" +%s 2> /dev/null || echo 0) )); then
    local f
    for f in "${CERT_FILES[@]}"; do rm -f "${FILES_DIR}/${f}.prev"; done
    state_set 'del(.adminPreviousRemoveAfter)' || log "WARNING: could not update ${STATE_FILE}"
    log "the copies of the previous admin certificate (grace period over) are deleted"
  fi
  return 0
}

rotate_locked() { # [force]
  recover_interrupted || return 1
  maintenance
  local left
  left="$(days_left "${FILES_DIR}/admin.pem")" || { log "ERROR: cannot read ${FILES_DIR}/admin.pem"; emit_failed; return 1; }
  if [[ "${1:-}" != "force" ]] && (( left > RENEW_DAYS )); then
    log "the admin certificate has ${left} days left (renewal at ${RENEW_DAYS} or fewer): nothing to do"
    return 0
  fi
  log "rotating the admin certificate (${left} days left)"
  umask 077
  mkdir -p "${TMPFS_DIR}"
  chmod 700 "${TMPFS_DIR}"
  WORK="$(mktemp -d "${TMPFS_DIR}/rotate-admin.XXXXXX")" && cd "${WORK}" \
    || { WORK=""; log "ERROR: cannot make a work directory in ${TMPFS_DIR}"; emit_failed; return 1; }
  # 1 to 3: build, check, register, and prove that TAK Server accepts it. The EFS is not touched.
  if ! build_new || ! register_admin "${WORK}/admin.pem" || ! check_registered "${WORK}/admin.pem" \
     || ! api_accepts "${WORK}/admin.pem" "${WORK}/admin.key" "${KS_PASS}"; then
    log "ERROR: the new certificate was not accepted; no file was changed"
    # the registration may have gone through: put the current certificate back
    register_admin "${FILES_DIR}/admin.pem" || log "WARNING: could not register the current certificate again; the next start does it"
    emit_failed
    return 1
  fi
  # 4: swap
  if ! install_new; then
    log "ERROR: installing the new certificate failed; restoring the previous files"
    if restore_previous && check_set "${FILES_DIR}"; then
      find "${MARKER}" -delete
      log "the previous admin certificate is back in place"
    else
      log "ERROR: could not restore the previous files; the marker stays and the next run tries again"
    fi
    emit_failed
    return 1
  fi
  find "${MARKER}" -delete
  log "admin certificate rotated: new notAfter $(openssl x509 -in "${FILES_DIR}/admin.pem" -noout -enddate | cut -d= -f2)"
  # 5 and 6
  local pending=false
  update_secret || pending=true
  state_set --arg notAfter "$(openssl x509 -in "${FILES_DIR}/admin.pem" -noout -enddate | cut -d= -f2)" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg remove "$(date -u -d "+${GRACE_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)" --argjson pending "${pending}" \
    '.notAfter.admin = $notAfter | .adminCertRotatedAt = $at | .adminPreviousRemoveAfter = $remove | (if $pending then .adminSecretPending = true else del(.adminSecretPending) end)' \
    || log "WARNING: could not update ${STATE_FILE}"
  "${METRICS}" emit AdminCertRotated 1 || true
  if [[ "${pending}" == "true" ]]; then
    log "ERROR: the new files are installed, but the secret still holds the old admin.p12; the next run tries again"
    emit_failed
    return 1
  fi
  return 0
}

main() {
  local cmd="${1:-}"
  [[ "${cmd}" == "check" || "${cmd}" == "rotate" ]] || { echo "usage: ${0##*/} check|rotate" >&2; exit 64; }
  if [[ -z "${PKI_KMS_CA_KEYS:-}" || ! -f "${STATE_FILE}" ]]; then
    log "admin certificate rotation: not applicable (no first-boot PKI on this stack)"
    exit 0
  fi
  load_settings
  RENEW_DAYS="$(int_setting PKI_ADMIN_CERT_RENEW_DAYS 60)"
  GRACE_DAYS="$(int_setting PKI_ADMIN_CERT_GRACE_DAYS 7)"
  (( RENEW_DAYS < ADMIN_DAYS )) || die "PKI_ADMIN_CERT_RENEW_DAYS (${RENEW_DAYS}) must be smaller than PKI_ADMIN_CERT_DAYS (${ADMIN_DAYS})"
  # From here a failure is reported by the functions, not by exiting
  die() { log "ERROR: $*"; return 1; }
  if [[ "${cmd}" == "check" && ! -f "${MARKER}" ]]; then
    local left pending after
    left="$(days_left "${FILES_DIR}/admin.pem")" || { log "ERROR: cannot read ${FILES_DIR}/admin.pem"; emit_failed; exit 1; }
    pending="$(jq -r '.adminSecretPending // false' "${STATE_FILE}")"
    after="$(jq -r '.adminPreviousRemoveAfter // empty' "${STATE_FILE}")"
    if (( left > RENEW_DAYS )) && [[ "${pending}" != "true" ]] && { [[ -z "${after}" ]] || (( $(date +%s) < $(date -d "${after}" +%s 2> /dev/null || echo 0) )); }; then
      log "admin certificate: ${left} days left (renewal at ${RENEW_DAYS} or fewer)"
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
