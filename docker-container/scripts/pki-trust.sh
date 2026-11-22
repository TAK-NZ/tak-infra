#!/bin/bash
# pki-trust.sh - the truststores and the signing keystore of TAK Server (#171, slice B). A command line for the
# functions of pki-trust-lib.sh, which the rotation scenarios call directly (read the header of that file).
#
#   pki-trust.sh show                              the manifest and what the truststore files hold
#   pki-trust.sh add <alias> <pem> <set,set,...>   put a CA certificate into the manifest (sets: server phone fed)
#   pki-trust.sh remove <alias>                    take it out
#   pki-trust.sh apply                             rebuild the truststores from the manifest (exit 10: changed, TAK
#                                                  Server must restart to load them; 0: nothing to do)
#   pki-trust.sh install-signing <N> <p12>         store Enrollment CA N as a secret and make it the current one
#   pki-trust.sh retire-signing <N>                destroy the key of Enrollment CA N, which is not in use any more: the
#                                                  secret is deleted with a recovery window of 30 days (N = 1: its value is
#                                                  overwritten). Refuses the current one and one that is still trusted
# Changes go through the cluster lock `pki-rotation`, the same as the orchestrator's.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_BOOTSTRAP_SOURCE_ONLY=1
# shellcheck source=pki-bootstrap.sh
source "${SCRIPT_DIR}/pki-bootstrap.sh"
LOCK_NAME="pki-rotation"
show() {
  trust_ensure_manifest || die "cannot write the manifest"
  echo "Manifest (${STATE_FILE}):"
  jq -r '.trust.entries[] | "  \(.alias)  \(.file)  sets: \(.sets | join(","))"' "${STATE_FILE}"
  local set
  for set in "${TRUST_SETS[@]}"; do
    echo "${set}: $(trust_jks_name "${set}")"
    jks_entries "${FILES_DIR}/$(trust_jks_name "${set}")" | sed 's/^/  /'
  done
  echo "Current signing keystore secret: $(signing_current_secret)"
}
main() {
  local cmd="${1:-}" rc=0
  [[ -f "${STATE_FILE}" ]] || { log "trust: not applicable (no first-boot PKI on this stack)"; exit 0; }
  case "${cmd}" in
    show) show ;;
    add) [[ $# -eq 4 ]] || { echo "usage: ${0##*/} add <alias> <pem> <set,set,...>" >&2; exit 64; }
      with_cluster_lock "${LOCK_NAME}" trust_add "$2" "$3" "$4" || rc=$? ;;
    remove) [[ $# -eq 2 ]] || { echo "usage: ${0##*/} remove <alias>" >&2; exit 64; }
      with_cluster_lock "${LOCK_NAME}" trust_remove "$2" || rc=$? ;;
    apply) with_cluster_lock "${LOCK_NAME}" trust_apply || rc=$? ;;
    install-signing) [[ $# -eq 3 && "$2" =~ ^[0-9]+$ ]] || { echo "usage: ${0##*/} install-signing <N> <p12>" >&2; exit 64; }
      with_cluster_lock "${LOCK_NAME}" signing_install "$2" "$3" || rc=$? ;;
    retire-signing) [[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]] || { echo "usage: ${0##*/} retire-signing <N>" >&2; exit 64; }
      with_cluster_lock "${LOCK_NAME}" signing_destroy "$2" || rc=$? ;;
    *) echo "usage: ${0##*/} show|add|remove|apply|install-signing|retire-signing" >&2; exit 64 ;;
  esac
  (( rc == 10 )) && log "the truststores changed: TAK Server loads them at its next start"
  exit "${rc}"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
