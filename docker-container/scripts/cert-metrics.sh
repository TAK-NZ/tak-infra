#!/bin/bash
# cert-metrics.sh - CloudWatch metrics for the certificate work (#129, architecture in #171).
#
# One helper for every part of the certificate rotation work, so nothing duplicates the
# instrumentation. Metrics go to the namespace TAK/Certificates with the dimension
# Stack=<$StackName>; the alarms in lib/constructs/certificate-alarms.ts watch them.
#
# Use as a command:
#   cert-metrics.sh emit <MetricName> [value] [Dimension=Value ...]
#   cert-metrics.sh check-expiry
# or source it (CERT_METRICS_SOURCE_ONLY=1) and call: emit_metric <MetricName> [value] [Dimension=Value ...]
#
# Emitting never fails the caller: a rotation step must not stop because CloudWatch is unreachable.
# The only exit code other than 0 is 2, for a command line mistake.
#
# check-expiry reads the CA certificates in $PKI_FILES_DIR (default /opt/tak/certs/files) and emits,
# every time, 0 or 1 for:
#   RootCAExpiryWarning          Root CA expires in PKI_ROOT_WARN_DAYS (730) days or less
#   IntermediateCAExpiryWarning  Intermediate CA expires in PKI_INTERMEDIATE_WARN_DAYS (1275 = 2W + 1 year) days or less
#   CAExpired                    the Root CA, Intermediate CA or Enrollment CA has expired
# Emitting 0 as well keeps the alarms honest: a missing datapoint would say "no data", not "fine".
# It does nothing on a stack without pki-state.json (a PKI from the old scripts).
set -uo pipefail

CERT_METRICS_NAMESPACE="TAK/Certificates"
# The metrics the alarms in #129 know about. A typo would silently feed no alarm, so unknown names are refused.
CERT_METRICS_KNOWN=(
  CertbotRenewalFailure TakServerCertRotated TakServerCertRotationFailed AdminCertRotated AdminCertRotationFailed SigningCARotated
  IntermediateCAExpiryWarning IntermediateCARotationPhase RootCAExpiryWarning RootCARotated
  RotationCoverageStragglers CAExpired RotationStepFailed RotationWaiting RotationSpareKeyMissing
)

cm_log() { echo "Cert metrics - $*" >&2; }

# emit_metric <MetricName> [value] [Dimension=Value ...]
emit_metric() {
  local name="${1:-}" value="${2:-1}"
  [[ $# -ge 2 ]] && shift 2 || shift $#
  local ok=0 m
  for m in "${CERT_METRICS_KNOWN[@]}"; do [[ "${m}" == "${name}" ]] && ok=1; done
  if [[ "${ok}" -ne 1 ]]; then cm_log "unknown metric '${name}' not emitted"; return 2; fi
  if [[ ! "${value}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then cm_log "value '${value}' of ${name} is not a number; not emitted"; return 2; fi
  local dims="Stack=${StackName:-unknown}" d
  for d in "$@"; do
    if [[ ! "${d}" =~ ^[A-Za-z][A-Za-z0-9]*=[A-Za-z0-9._-]+$ ]]; then cm_log "dimension '${d}' of ${name} is not Name=Value; not emitted"; return 2; fi
    dims="${dims},${d}"
  done
  if ! aws cloudwatch put-metric-data --namespace "${CERT_METRICS_NAMESPACE}" --metric-name "${name}" \
       --value "${value}" --unit Count --dimensions "${dims}" > /dev/null 2>&1; then
    cm_log "could not emit ${name}=${value} (${dims}); continuing"
    return 0
  fi
  cm_log "${name}=${value} (${dims})"
  return 0
}

# days until a certificate expires (negative when it has expired); empty when it cannot be read
days_left() {
  local end epoch
  end="$(openssl x509 -in "$1" -noout -enddate 2> /dev/null | cut -d= -f2)" || return 1
  [[ -n "${end}" ]] || return 1
  epoch="$(date -d "${end}" +%s 2> /dev/null)" || return 1
  # CERT_METRICS_NOW (epoch seconds) lets the tests move the clock
  echo $(( (epoch - ${CERT_METRICS_NOW:-$(date +%s)}) / 86400 ))
}

check_expiry() {
  local dir="${PKI_FILES_DIR:-/opt/tak/certs/files}"
  if [[ ! -f "${dir}/pki-state.json" ]]; then
    cm_log "no ${dir}/pki-state.json (not a stack with the first-boot PKI): nothing to check"
    return 0
  fi
  local root_warn="${PKI_ROOT_WARN_DAYS:-730}" inter_warn="${PKI_INTERMEDIATE_WARN_DAYS:-1275}"
  [[ "${root_warn}" =~ ^[0-9]+$ && "${inter_warn}" =~ ^[0-9]+$ ]] || { cm_log "PKI_ROOT_WARN_DAYS and PKI_INTERMEDIATE_WARN_DAYS must be numbers"; return 2; }

  local root inter enroll expired=0 root_flag=0 inter_flag=0
  root="$(days_left "${dir}/root-ca.pem")" || { cm_log "cannot read ${dir}/root-ca.pem"; return 0; }
  inter="$(days_left "${dir}/intermediate-ca.pem")" || { cm_log "cannot read ${dir}/intermediate-ca.pem"; return 0; }
  enroll="$(days_left "${dir}/enrollment-ca.pem")" || { cm_log "cannot read ${dir}/enrollment-ca.pem"; return 0; }
  cm_log "Root CA: ${root} days left (warning at ${root_warn}), Intermediate CA: ${inter} days left (warning at ${inter_warn}), Enrollment CA: ${enroll} days left"

  (( root <= root_warn )) && root_flag=1
  (( inter <= inter_warn )) && inter_flag=1
  (( root < 0 || inter < 0 || enroll < 0 )) && expired=1

  emit_metric RootCAExpiryWarning "${root_flag}"
  emit_metric IntermediateCAExpiryWarning "${inter_flag}"
  emit_metric CAExpired "${expired}"
  return 0
}

main() {
  case "${1:-}" in
    emit)         shift; [[ $# -ge 1 ]] || { echo "usage: cert-metrics.sh emit <MetricName> [value] [Dimension=Value ...]" >&2; exit 2; }; emit_metric "$@"; exit $? ;;
    check-expiry) check_expiry; exit $? ;;
    *) echo "usage: cert-metrics.sh emit <MetricName> [value] [Dimension=Value ...] | check-expiry" >&2; exit 2 ;;
  esac
}

if [[ "${CERT_METRICS_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
