#!/bin/bash
# admin-p12-reexport.sh - make admin.p12 readable by OpenSSL 3 without the legacy provider (#132).
#
#   admin-p12-reexport.sh [--dry-run] [--no-secret]
#
# The admin.p12 that TAK Server's makeCert.sh writes has its certificates encrypted with RC2-40 (plain
# `-legacy`). OpenSSL 3 without the legacy provider cannot read that ("unsupported ... RC2-40-CBC"), so a
# third-party system that loads it fails. This script exports the same key and certificates again with the
# compat3des profile of #171 (`-legacy -descert`: 3DES for certificates and key, SHA-1 MAC), which OpenSSL 3
# and Node read. It is for stacks that still have the PKI of the TAK Server scripts: the first-boot PKI
# (pki-bootstrap.sh) already writes this profile, and the script then finds nothing to do.
#
# Steps: open the old file with the legacy provider; export again; check that the new file opens without it
# and holds the same certificates and key; keep the old file as admin.p12.rc2; replace admin.p12 (rename);
# store it in Secrets Manager (<StackName>/TAK-Server/Admin-Cert, with the file hash as the request token,
# the same as start-tak.sh, so a later start sees "unchanged"). The file is replaced before the secret is
# written: a failed secret update is then repaired by the next start, which uploads the file. The other
# way round, the next start would put the old file back into the secret.
#
# Exit status: 0 done, or nothing to do; 1 error; 64 usage; 75 another node is running it.
#
# Environment: PKI_FILES_DIR (/opt/tak/certs/files), P12_PASSWORD (atakatak), StackName (for the secret),
# CLUSTER_LOCK_* (docs/CLUSTER_LOCK.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${PKI_FILES_DIR:-/opt/tak/certs/files}"
P12="${FILES_DIR}/admin.p12"
PASS="${P12_PASSWORD:-atakatak}"
DRY_RUN=0
UPDATE_SECRET=1
WORK=""
# the work directory holds the key in clear text: always removed
cleanup() { [[ -n "${WORK}" && -d "${WORK}" ]] && { find "${WORK}" -type f -delete 2> /dev/null; rmdir "${WORK}" 2> /dev/null; }; return 0; }
trap cleanup EXIT
log() { echo "TAK Server - admin.p12: $*"; }
die() { echo "TAK Server - admin.p12: ERROR: $*" >&2; exit 1; }

# the fingerprints of all certificates in a p12, sorted; nothing if it cannot be opened
cert_fps() { # p12 [openssl option...]
  local p12="$1" out buf="" line
  shift
  out="$(openssl pkcs12 "$@" -in "${p12}" -passin "pass:${PASS}" -nokeys 2> /dev/null)" || return 0
  while IFS= read -r line; do
    case "${line}" in
      "-----BEGIN CERTIFICATE-----") buf="${line}"$'\n' ;;
      "-----END CERTIFICATE-----")
        buf+="${line}"$'\n'
        printf '%s' "${buf}" | openssl x509 -noout -fingerprint -sha256
        buf="" ;;
      *) [[ -z "${buf}" ]] || buf+="${line}"$'\n' ;;
    esac
  done <<< "${out}"
}
key_fp() { # p12 [openssl option...]
  local p12="$1"
  shift
  openssl pkcs12 "$@" -in "${p12}" -passin "pass:${PASS}" -nocerts -nodes 2> /dev/null | openssl pkey -pubout 2> /dev/null | openssl sha256 2> /dev/null
}

reexport() {
  [[ -s "${P12}" ]] || die "${P12} does not exist"
  # Readable without the legacy provider: nothing to do (also true for a first-boot PKI stack)
  if [[ -n "$(cert_fps "${P12}")" && -n "$(key_fp "${P12}")" ]]; then
    log "already readable by OpenSSL 3 without the legacy provider: nothing to do"
    return 0
  fi
  [[ -n "$(cert_fps "${P12}" -legacy)" && -n "$(key_fp "${P12}" -legacy)" ]] \
    || die "cannot open ${P12} with the password in P12_PASSWORD, even with the legacy provider"
  umask 077
  if [[ -d /dev/shm && -w /dev/shm ]]; then WORK="$(mktemp -d /dev/shm/admin-p12.XXXXXX)"; else WORK="$(mktemp -d)"; fi
  local work="${WORK}"
  log "exporting ${P12} again (certificates 3DES, SHA-1 MAC)"
  openssl pkcs12 -legacy -in "${P12}" -passin "pass:${PASS}" -nodes -out "${work}/all.pem" 2> /dev/null || die "cannot read ${P12}"
  openssl pkcs12 -export -legacy -descert -in "${work}/all.pem" -name admin -out "${work}/admin.p12" -passout "pass:${PASS}" 2> /dev/null \
    || die "cannot export the new file"
  # Same certificates, same key, and readable without the legacy provider
  [[ -n "$(cert_fps "${work}/admin.p12")" ]] || die "check: the new file is not readable without the legacy provider"
  [[ "$(cert_fps "${work}/admin.p12")" == "$(cert_fps "${P12}" -legacy)" ]] || die "check: the new file holds other certificates"
  [[ "$(key_fp "${work}/admin.p12")" == "$(key_fp "${P12}" -legacy)" ]] || die "check: the new file holds another key"
  if (( DRY_RUN )); then
    log "dry run: the new file passed the checks; nothing was changed"
    return 0
  fi
  if [[ ! -e "${P12}.rc2" ]]; then
    cp -p "${P12}" "${P12}.rc2" || die "cannot keep a copy of the old file"
    log "the old file is kept as ${P12}.rc2"
  fi
  cp "${work}/admin.p12" "${P12}.new" && chmod 600 "${P12}.new" && mv -f "${P12}.new" "${P12}" || die "cannot replace ${P12}"
  log "${P12} replaced"
  if (( UPDATE_SECRET )); then
    [[ -n "${StackName:-}" ]] || die "StackName is not set, so the secret cannot be named (the file is replaced; the next start uploads it, or run again with --no-secret to skip this)"
    if aws secretsmanager put-secret-value --secret-id "${StackName}/TAK-Server/Admin-Cert" --secret-binary "fileb://${P12}" \
         --client-request-token "$(sha256sum "${P12}" | cut -d' ' -f1)" > /dev/null 2> "${work}/aws.err"; then
      log "the secret ${StackName}/TAK-Server/Admin-Cert is updated (the old version stays as AWSPREVIOUS)"
    elif grep -q "ClientRequestTokenConflictException" "${work}/aws.err"; then
      log "the secret already holds this file"
    else
      echo "TAK Server - admin.p12: ERROR: could not update the secret (the file is replaced; the next start uploads it): $(head -c 300 "${work}/aws.err")" >&2
      return 1
    fi
  fi
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-secret) UPDATE_SECRET=0 ;;
    *) echo "usage: ${0##*/} [--dry-run] [--no-secret]" >&2; exit 64 ;;
  esac
  shift
done
export CLUSTER_LOCK_DIR="${CLUSTER_LOCK_DIR:-${FILES_DIR}/.locks}"
export CLUSTER_LOCK_WAIT="${CLUSTER_LOCK_WAIT:-120}"
# shellcheck source=cluster-lock.sh
source "${SCRIPT_DIR}/cluster-lock.sh"
rc=0
with_cluster_lock admin-p12-reexport reexport || rc=$?
exit "${rc}"
