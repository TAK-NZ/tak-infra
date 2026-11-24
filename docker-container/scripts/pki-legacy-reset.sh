#!/bin/bash
# pki-legacy-reset.sh - move a stack from the PKI of the TAK Server scripts to the first-boot PKI (#136, #189).
#
#   pki-legacy-reset.sh reset [--dry-run] [--restart]   move the old PKI files aside; the next start builds the new PKI
#   pki-legacy-reset.sh restore <dir>                   put them back (only before the new PKI was built)
#   pki-legacy-reset.sh purge <dir>                     delete the moved files for good (after the new PKI works)
#
# Why. A stack that was built before `pki.kmsCa` has the PKI that makeRootCa.sh and makeCert.sh wrote: the CA keys are files on
# the EFS and nothing renews or rotates the certificates. pki-bootstrap.sh does not touch such a stack ("already has a PKI from
# the old flow"): it builds the new PKI only when ca.pem is not there. There is no migration of the certificates: the new
# hierarchy has other CAs, so **every phone has to enrol again** (QR code), federation peers need the new FederateCA, and data
# packages made before are dead. Flag day. The database, the users and the Let's Encrypt certificate are not touched.
#
# What `reset` does, under the cluster lock of pki-bootstrap.sh:
#  1. Refuses unless the stack is set up for the new PKI (PKI_KMS_CA_KEYS, PKI_ENV_LABEL, ... pass the checks of
#     pki-bootstrap.sh and the secret of the Enrollment CA exists), has no pki-state.json yet, and has ca.pem.
#  2. Moves the files of the old PKI (CA keys and certificates, server and admin certificate, truststores) into
#     <files dir>/legacy-pki-<UTC time>/ (mode 700; a rename on the same file system, ca.pem last). A run that was
#     interrupted continues with the same directory. Not moved: the Let's Encrypt files, aws-acm-root.jks, the oauth key,
#     the locks, and client packages that someone made by hand.
#  3. With --restart it starts the rolling deployment; otherwise it says what to run. The next start of a node builds the
#     new PKI (pki-bootstrap.sh), uploads the new admin.p12 and FederateCA to Secrets Manager, and registers the admin.
# `--dry-run` checks everything and lists what would move.
#
# After the new stack works: `purge <dir>` deletes the moved files (they hold the old CA keys). `restore <dir>` is for the
# case that the stack did not start with the new PKI and nothing was built: it refuses when pki-state.json exists.
#
# Exit status: 0 done, or nothing to do; 1 refused or failed; 64 usage; 75 another node holds the lock.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_BOOTSTRAP_SOURCE_ONLY=1
# shellcheck source=pki-bootstrap.sh
source "${SCRIPT_DIR}/pki-bootstrap.sh"
# shellcheck source=pki-rotate-common.sh
source "${SCRIPT_DIR}/pki-rotate-common.sh"
MARKER="${FILES_DIR}/.legacy-reset"
LOCK_NAME="pki-bootstrap"
# the files that makeRootCa.sh, makeCert.sh and the first-boot code of start-tak.sh write; ca.pem is moved last
LEGACY_FILES=(
  admin.csr admin.jks admin.key admin.p12 admin.p12.rc2 admin.pem admin-trusted.pem
  ca.crl ca-do-not-share.key ca-trusted.pem crl_index.txt crl_index.txt.attr
  intermediate-ca.crl intermediate-ca.csr intermediate-ca.key intermediate-ca.pem intermediate-ca-signing.jks intermediate-ca-signing.p12 intermediate-ca-trusted.pem
  root-ca-do-not-share.key root-ca.pem root-ca-trusted.pem
  takserver.csr takserver.jks takserver.key takserver.p12 takserver.pem takserver-trusted.pem
  truststore-intermediate-ca.jks truststore-intermediate-ca.p12 truststore-root.jks truststore-root.p12 fed-truststore.jks
  ca.pem
)
usage() {
  echo "usage: ${0##*/} reset [--dry-run] [--restart] | restore <dir> | purge <dir>" >&2
  exit 64
}
# a legacy directory name, given as a name or a path: only legacy-pki-<time> under the files directory
legacy_dir() { # arg -> path, or nothing
  local n
  n="$(basename "$1")"
  [[ "${n}" =~ ^legacy-pki-[0-9]{8}T[0-9]{6}Z$ ]] && [[ -d "${FILES_DIR}/${n}" ]] && echo "${FILES_DIR}/${n}"
}
# What `pki-bootstrap.sh` needs, checked before anything moves
preflight() {
  [[ -n "${PKI_KMS_CA_KEYS:-}" ]] || { log "refused: PKI_KMS_CA_KEYS is not set: this stack is not set up for the new PKI (pki.kmsCa.enabled, then deploy). Without it the next start would only build the old PKI again"; return 1; }
  [[ ! -f "${STATE_FILE}" ]] || { log "refused: ${STATE_FILE} exists: this stack has the new PKI already"; return 1; }
  if [[ ! -f "${FILES_DIR}/ca.pem" && ! -f "${MARKER}" ]]; then
    log "there is no ca.pem: nothing to reset (the next start builds the new PKI)"
    return 2
  fi
  ( load_settings ) > /dev/null 2>&1 || { log "refused: the settings of the new PKI do not pass the checks of pki-bootstrap.sh:"; ( load_settings ) 2>&1 | sed 's/^/    /' >&2; return 1; }
  aws secretsmanager describe-secret --secret-id "${PKI_ENROLLMENT_CA_SECRET}" > /dev/null 2>&1 \
    || { log "refused: the secret ${PKI_ENROLLMENT_CA_SECRET} of the Enrollment CA cannot be read (is the stack deployed with pki.kmsCa?)"; return 1; }
  return 0
}
reset_locked() {
  local dry="$1" dir f n=0 stamp rc=0
  preflight || return $?
  if [[ -f "${MARKER}" ]]; then
    dir="${FILES_DIR}/$(cat "${MARKER}")"
    [[ -d "${dir}" ]] || { log "refused: ${MARKER} names ${dir}, which is not there"; return 1; }
    log "an earlier reset was interrupted: continuing with ${dir}"
  else
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    dir="${FILES_DIR}/legacy-pki-${stamp}"
  fi
  for f in "${LEGACY_FILES[@]}"; do [[ -e "${FILES_DIR}/${f}" ]] && n=$(( n + 1 )); done
  if (( dry )); then
    log "dry run: ${n} file(s) would move into ${dir}:"
    for f in "${LEGACY_FILES[@]}"; do [[ -e "${FILES_DIR}/${f}" ]] && echo "    ${f}"; done
    log "dry run: nothing was changed. The checks of the new PKI passed"
    return 0
  fi
  if [[ ! -f "${MARKER}" ]]; then
    ( umask 077; mkdir -p "${dir}" ) || { log "ERROR: cannot create ${dir}"; return 1; }
    basename "${dir}" > "${MARKER}.new" && mv -f "${MARKER}.new" "${MARKER}" || { log "ERROR: cannot write ${MARKER}"; return 1; }
  fi
  for f in "${LEGACY_FILES[@]}"; do
    [[ -e "${FILES_DIR}/${f}" ]] || continue
    mv "${FILES_DIR}/${f}" "${dir}/${f}" || { log "ERROR: cannot move ${f}; run it again (it continues with ${dir})"; return 1; }
  done
  find "${MARKER}" -delete
  log "the old PKI (${n} files, with the CA keys) is in ${dir}"
  log "the next start of TAK Server builds the new PKI. Every phone has to enrol again; federation peers need the new FederateCA"
  log "when it works: ${0##*/} purge ${dir##*/}"
  return "${rc}"
}
cmd_reset() {
  local dry=0 restart=0 rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --dry-run) dry=1 ;; --restart) restart=1 ;; *) usage ;; esac
    shift
  done
  CLUSTER_LOCK_WAIT="${CLUSTER_LOCK_WAIT:-120}"
  with_cluster_lock "${LOCK_NAME}" reset_locked "${dry}" || rc=$?
  (( rc == 2 )) && exit 0
  (( rc == 0 )) || exit "${rc}"
  (( dry )) && exit 0
  if (( restart )); then
    trigger_deployment || { log "ERROR: the rolling deployment could not be started: start one (aws ecs update-service --cluster ${ECS_Cluster_Name:-<cluster>} --service ${ECS_Service_Name:-<service>} --force-new-deployment)"; exit 1; }
  else
    log "start the rolling deployment: aws ecs update-service --cluster ${ECS_Cluster_Name:-<cluster>} --service ${ECS_Service_Name:-<service>} --force-new-deployment"
  fi
}
restore_locked() {
  local dir="$1" f n=0
  [[ ! -f "${STATE_FILE}" ]] || { log "refused: ${STATE_FILE} exists: the new PKI was built. Restoring the old files now would mix two PKIs"; return 1; }
  [[ ! -e "${FILES_DIR}/ca.pem" ]] || { log "refused: ${FILES_DIR}/ca.pem exists: there is a PKI in the files directory"; return 1; }
  for f in "${LEGACY_FILES[@]}"; do [[ -e "${dir}/${f}" ]] && n=$(( n + 1 )); done
  # ca.pem first: with it back the old flow is complete again
  for f in ca.pem "${LEGACY_FILES[@]}"; do
    [[ -e "${dir}/${f}" ]] || continue
    mv "${dir}/${f}" "${FILES_DIR}/${f}" || { log "ERROR: cannot move ${f} back"; return 1; }
  done
  find "${MARKER}" -delete 2> /dev/null
  rmdir "${dir}" 2> /dev/null || log "${dir} still holds files that are not part of the old PKI"
  log "the old PKI (${n} files) is back; restart TAK Server (rolling deployment)"
}
purge_locked() {
  local dir="$1"
  [[ -f "${STATE_FILE}" ]] || { log "refused: there is no ${STATE_FILE}: the new PKI is not built, and ${dir} is the only copy of the old one"; return 1; }
  find "${dir}" -delete || { log "ERROR: cannot delete ${dir}"; return 1; }
  log "${dir} is deleted (the old CA keys are gone)"
}
main() {
  local cmd="${1:-}" dir rc=0
  [[ -n "${cmd}" ]] || usage
  shift
  case "${cmd}" in
    reset) cmd_reset "$@" ;;
    restore | purge)
      [[ $# -eq 1 ]] || usage
      dir="$(legacy_dir "$1")" || true
      [[ -n "${dir}" ]] || { log "refused: '$1' is not a directory legacy-pki-<time> in ${FILES_DIR}"; exit 1; }
      CLUSTER_LOCK_WAIT="${CLUSTER_LOCK_WAIT:-120}"
      with_cluster_lock "${LOCK_NAME}" "${cmd}_locked" "${dir}" || rc=$?
      exit "${rc}"
      ;;
    *) usage ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
