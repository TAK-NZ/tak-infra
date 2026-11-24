#!/bin/bash
# Helpers shared by the rotation scripts server-cert-rotate.sh (#131) and admin-cert-rotate.sh (#132).
# Sourced after pki-bootstrap.sh (which provides log and the settings). Defines no state of its own.
_ROTATE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS="${_ROTATE_COMMON_DIR}/cert-metrics.sh"
emit() { "${METRICS}" emit "$1" 1 || true; }
days_left() { # pem -> whole days until notAfter (negative when expired)
  local end
  end="$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" || return 1
  echo $(( ($(date -d "${end}" +%s) - $(date +%s)) / 86400 ))
}
pub_of_cert() { openssl x509 -in "$1" -noout -pubkey 2> /dev/null | openssl sha256 2> /dev/null; }
pub_of_key() { openssl pkey -in "$1" -pubout 2> /dev/null | openssl sha256 2> /dev/null; }
fp_of_cert() { openssl x509 -in "$1" -noout -fingerprint -sha256 2> /dev/null; }
# A rolling deployment makes every node load new keystores (TAK Server reads them only at start).
# PKI_ROTATE_NO_DEPLOY=1 skips it (tests; the old name SERVER_CERT_ROTATE_NO_DEPLOY works too).
trigger_deployment() {
  if [[ "${PKI_ROTATE_NO_DEPLOY:-${SERVER_CERT_ROTATE_NO_DEPLOY:-0}}" == "1" ]]; then log "deployment skipped (PKI_ROTATE_NO_DEPLOY=1)"; return 0; fi
  if [[ -z "${ECS_Cluster_Name:-}" || -z "${ECS_Service_Name:-}" ]]; then log "ECS_Cluster_Name or ECS_Service_Name is not set"; return 1; fi
  local i
  for i in 1 2 3; do
    if aws ecs update-service --cluster "${ECS_Cluster_Name}" --service "${ECS_Service_Name}" --force-new-deployment > /dev/null 2>&1; then
      log "rolling deployment started: every node loads the new certificates"
      return 0
    fi
    sleep "${PKI_ROTATE_RETRY_DELAY:-${SERVER_CERT_ROTATE_RETRY_DELAY:-5}}"
  done
  return 1
}
