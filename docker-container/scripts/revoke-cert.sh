#!/bin/bash
# revoke-cert.sh - revoke a client certificate of an Enrollment CA (#204).
#
#   revoke-cert.sh <cert.pem> [--reason REASON] [--no-restart]
#   revoke-cert.sh --serial HEX --ca enrollment-ca-NN --subject /O=TAK.NZ/CN=name --not-after DATE [--reason REASON] [--no-restart]
#   revoke-cert.sh --list
#
# The certificate goes into the CRL of the Enrollment CA that issued it (pki-crl-lib.sh), which is signed with that
# CA's key and written to /opt/tak/certs/files/crl. TAK Server reads CRLs only at start, so unless --no-restart is
# given the script starts a rolling deployment (4 to 9 minutes until the revocation is in force; the old task keeps
# serving until the new one is healthy). The revocation is per certificate: another certificate with the same CN keeps
# working. Reasons: unspecified (default), keyCompromise, CACompromise, affiliationChanged, superseded,
# cessationOfOperation, certificateHold. For a certificate that TAK Server issued itself through enrolment, TAK
# Server's own revocation (certadmin API) is immediate and needs no restart; this is for certificates it does not
# know, such as the admin certificate, and for a leaked key.
# Emits the metric CertificateRevoked (alert, #129). Takes the cluster lock `pki-rotation`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_BOOTSTRAP_SOURCE_ONLY=1
# shellcheck source=pki-bootstrap.sh
source "${SCRIPT_DIR}/pki-bootstrap.sh"
# shellcheck source=pki-rotate-common.sh
source "${SCRIPT_DIR}/pki-rotate-common.sh"
usage() { sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
list() {
  local a
  while IFS= read -r a; do
    echo "${a} ($(crl_file "${a}")):"
    awk -F'\t' '$1 == "R" {print "  serial " $4 "  " $6 "  revoked " $3}' "${CRL_DIR}/db/${a}/index.txt" 2> /dev/null
    [[ -s "${CRL_DIR}/db/${a}/index.txt" ]] || echo "  (nothing revoked)"
  done < <(crl_aliases)
}
main() {
  local pem="" serial="" ca="" subject="" notafter="" reason="unspecified" restart=1 do_list=0 rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --serial) serial="${2:-}"; shift ;;
      --ca) ca="${2:-}"; shift ;;
      --subject) subject="${2:-}"; shift ;;
      --not-after) notafter="${2:-}"; shift ;;
      --reason) reason="${2:-}"; shift ;;
      --no-restart) restart=0 ;;
      --list) do_list=1 ;;
      -h | --help) usage ;;
      -*) usage ;;
      *) [[ -z "${pem}" ]] || usage; pem="$1" ;;
    esac
    shift
  done
  [[ -f "${STATE_FILE}" ]] || { log "revoke-cert: not applicable (no first-boot PKI on this stack)"; exit 0; }
  trust_ensure_manifest || die "cannot write the trust manifest"
  if (( do_list )); then list; exit 0; fi
  if [[ -n "${pem}" && -z "${serial}" ]]; then
    with_cluster_lock pki-rotation crl_revoke_cert "${pem}" "${reason}" || rc=$?
  elif [[ -z "${pem}" && -n "${serial}" && -n "${ca}" && -n "${subject}" && -n "${notafter}" ]]; then
    with_cluster_lock pki-rotation crl_revoke_serial "${ca}" "${serial}" "${notafter}" "${subject}" "${reason}" || rc=$?
  else
    usage
  fi
  if (( rc == 10 )); then
    "${METRICS}" emit CertificateRevoked 1 || true
    if (( restart )); then
      trigger_deployment || { log "ERROR: the rolling deployment could not be started: the revocation is in force after the next start of TAK Server"; exit 1; }
    else
      log "no restart requested: the revocation is in force after the next start of TAK Server"
    fi
    exit 0
  fi
  exit "${rc}"
}
main "$@"
