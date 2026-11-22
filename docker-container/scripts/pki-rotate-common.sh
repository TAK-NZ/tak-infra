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
