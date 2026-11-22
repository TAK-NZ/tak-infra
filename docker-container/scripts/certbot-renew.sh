#!/bin/bash
# certbot-renew.sh - the Let's Encrypt renewal that cron runs (#130).
#
#   certbot-renew.sh          renew, under the cluster lock; emit CertbotRenewalFailure on failure
#   certbot-renew.sh write-env   write the environment cron jobs need (called by start-tak.sh)
#
# Why this is a script and not just `certbot -q renew` in the cron file:
# - Cron jobs do not get the container's environment. Without ECS_Cluster_Name and ECS_Service_Name the
#   certbot deploy hook (letsencrypt-deploy-hook-script.sh) exits at once, so a renewed certificate was
#   never loaded by TAK Server; and without AWS_CONTAINER_CREDENTIALS_RELATIVE_URI no AWS call has the
#   task role. `write-env` saves those variables for this script to load.
# - Two nodes must not renew at once: the renewal takes the cluster lock `certbot-renew` (#7) without
#   waiting. A node that finds it taken skips this round; the other node renews, and the certificate is
#   on the shared EFS.
# - A failed renewal is reported: the metric CertbotRenewalFailure (alarm and SNS alert from #129).
#
# Exit status: 0 renewed, nothing to renew, or skipped because another node renews; otherwise the
# status of certbot.
#
# Settings (environment): TAK_CRON_ENV_FILE (default /run/tak-cron.env), CERTBOT_BIN (default certbot).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${TAK_CRON_ENV_FILE:-/run/tak-cron.env}"
log() { echo "Certbot - renewal: $*"; }

write_env() {
  local name tmp="${ENV_FILE}.new"
  umask 077
  : > "${tmp}"
  # Only what the renewal, the deploy hook and the metric need
  while IFS= read -r name; do
    [[ "${name}" =~ ^(ECS_Cluster_Name|ECS_Service_Name|StackName|AWS_[A-Za-z0-9_]*)$ ]] || continue
    printf 'export %s=%q\n' "${name}" "${!name}" >> "${tmp}"
  done < <(compgen -e)
  mv -f "${tmp}" "${ENV_FILE}"
}

renew() {
  if [[ -r "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  else
    log "WARNING: ${ENV_FILE} is missing: the deploy hook and the failure metric cannot reach AWS"
  fi
  # shellcheck source=cluster-lock.sh
  source "${SCRIPT_DIR}/cluster-lock.sh"
  local rc=0
  CLUSTER_LOCK_WAIT=0 with_cluster_lock certbot-renew "${CERTBOT_BIN:-certbot}" -q renew || rc=$?
  case "${rc}" in
    0) log "done" ;;
    75) log "another node is renewing: skipped"; rc=0 ;;
    *)
      log "FAILED with status ${rc}"
      "${SCRIPT_DIR}/cert-metrics.sh" emit CertbotRenewalFailure 1 || true
      ;;
  esac
  return "${rc}"
}

case "${1:-}" in
  write-env) write_env ;;
  "") renew ;;
  *) echo "usage: ${0##*/} [write-env]" >&2; exit 64 ;;
esac
