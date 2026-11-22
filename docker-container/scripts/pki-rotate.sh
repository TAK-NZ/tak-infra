#!/bin/bash
# pki-rotate.sh - the rotation orchestrator of the PKI (#171).
#
#   pki-rotate.sh run                      the daily run (start-tak.sh calls it): leaf certificates, then the
#                                          orchestrated rotations, then the checks that raise alarms
#   pki-rotate.sh plan [--at DATE] [--json]  what happens when: every layer with its expiry and trigger date,
#                                          the active rotation with its gates. Changes nothing
#   pki-rotate.sh status                   the state file and what the active rotation waits for
#   pki-rotate.sh approve <scenario> <step>  release a step that needs an approval
#   pki-rotate.sh abort                    stop the active rotation (the scenario undoes what it can)
#
# Applies to stacks with the first-boot PKI of pki-bootstrap.sh (a state file exists); anything else exits 0.
#
# What it is for. The PKI has four layers that expire and must be replaced without a day on which phones stop
# working (#171): the server and admin certificates (leaf, #131, #132), the Enrollment CA (#135), the
# Intermediate CA (#172) and the Root CA (#169). The leaf certificates are replaced by their own scripts,
# which `run` calls first. The other three are *scenarios*: a sequence of steps with gates between them,
# kept in /opt/tak/certs/files/rotation-state.json, so that a rotation that takes more than a year survives
# restarts, crashes and node changes.
#
# Gates between steps (all of them must be open):
#   restart   TAK Server runs a task that started after the previous step (the previous step asked for a restart and
#             the rolling deployment has replaced the task): the step needs the new keystores to be loaded
#   window    W = client certificate validity + buffer (455 days by default) since the previous step, so that
#             every phone has received a certificate from the new chain before trust is removed (#171)
#   coverage  rotation-coverage.sh (arguments from the scenario: `<n>_coverage_args`) reports no active user who is
#             still on the old side. While it does, the list of users goes to the log and to the alert topic (SNS,
#             once a week for the same users) and RotationCoverageStragglers carries the number
#   approval  `pki-rotate.sh approve <scenario> <step>`; required for the steps named in
#             PKI_ROTATION_REQUIRE_APPROVAL (default: retire, the only destructive step)
#   A step can have a hard deadline (the expiry of what it depends on, minus a margin): from then on the
#   window and the coverage gate are open. The approval gate is never skipped, but the alarm RotationWaiting
#   tells a human that the rotation is stuck on it.
#
# A scenario is a file rotation/<name>.sh (here and in PKI_ROTATE_SCENARIO_DIR) with these functions, all
# prefixed with the name (hyphens as underscores):
#   <n>_summary           one line for plan: current|notAfter epoch|trigger epoch or -|note
#   <n>_due               returns 0 when a rotation must start now
#   <n>_steps             echoes the step names in order
#   <n>_gate <step>       echoes the gates of the step: none, or any of: restart window coverage approval
#   <n>_deadline <step>   echoes an epoch (optional)
#   <n>_coverage_args <step>  echoes the arguments of rotation-coverage.sh for a step with a coverage gate
#   <n>_run <step>        does the step. 0 done, 10 done and TAK Server must restart, anything else failed and is
#                         retried at the next run. Steps must be idempotent: after a crash the step runs again
#   <n>_abort             optional: undoes what can be undone. Return 2 when it cannot be undone any more: the rotation stays active
# A restart is requested once, after the state is saved (an ECS rolling deployment: TAK Server reads its
# truststore and signing keystore only at start).
#
# Metrics (#129): RotationStepFailed, RotationWaiting (1 when a rotation waits for an approval or the coverage
# check although its window is over), RotationSpareKeyMissing (Tier=root|intermediate: no key generation is left
# after the one in use; the keys are created by CDK, `pki.kmsCa.rootCaNumbers` / `intermediateCaNumbers`).
#
# Environment: the settings of pki-bootstrap.sh, plus PKI_CLIENT_CERT_DAYS (365), PKI_ROTATION_BUFFER_DAYS (90),
# PKI_ENROLLMENT_CA_ROTATION_DAYS (365), PKI_ROTATION_REQUIRE_APPROVAL (retire), PKI_ROTATION_NOW (epoch, for
# tests and `plan`), PKI_ROTATE_SCENARIO_DIR, PKI_ROTATE_COVERAGE_CMD, PKI_ROTATE_LEAF_SCRIPTS, PKI_ROTATE_NO_DEPLOY, PKI_ROTATE_TASK_STARTED (epoch, for the restart gate),
# PKI_ROTATE_BUILTIN_SCENARIOS=0 (tests).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_BOOTSTRAP_SOURCE_ONLY=1
# shellcheck source=pki-bootstrap.sh
source "${SCRIPT_DIR}/pki-bootstrap.sh"
# shellcheck source=pki-rotate-common.sh
source "${SCRIPT_DIR}/pki-rotate-common.sh"
ROT_STATE="${FILES_DIR}/rotation-state.json"
APPROVAL_DIR="${FILES_DIR}/.rotation-approvals"
LOCK_NAME="pki-rotation"
DAY=86400

now() { echo "${PKI_ROTATION_NOW:-$(date +%s)}"; }
fmt_date() { if [[ "$1" =~ ^[0-9]+$ ]]; then date -u -d "@$1" +%Y-%m-%d; else echo "-"; fi; }
cert_enddate() { date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s; }
cert_startdate() { date -d "$(openssl x509 -in "$1" -noout -startdate | cut -d= -f2)" +%s; }

load_rotation_settings() {
  CLIENT_DAYS="$(int_setting PKI_CLIENT_CERT_DAYS 365)"
  BUFFER_DAYS="$(int_setting PKI_ROTATION_BUFFER_DAYS 90)"
  CL_ROTATION_DAYS="$(int_setting PKI_ENROLLMENT_CA_ROTATION_DAYS 365)"
  WINDOW_DAYS=$(( CLIENT_DAYS + BUFFER_DAYS ))
  # an empty PKI_ROTATION_REQUIRE_APPROVAL switches the approvals off
  REQUIRE_APPROVAL=",${PKI_ROTATION_REQUIRE_APPROVAL-retire},"
  REQUIRE_APPROVAL="${REQUIRE_APPROVAL// /}"
  SERVER_RENEW="$(int_setting PKI_SERVER_CERT_RENEW_DAYS 60)"
  ADMIN_RENEW="$(int_setting PKI_ADMIN_CERT_RENEW_DAYS 60)"
}

# ---------------------------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------------------------
st_init() { [[ -f "${ROT_STATE}" ]] || { echo '{"version":1,"active":null,"history":[]}' > "${ROT_STATE}.new" && chmod 644 "${ROT_STATE}.new" && mv -f "${ROT_STATE}.new" "${ROT_STATE}"; }; }
st_get() { jq -r "$1" "${ROT_STATE}"; }
st_set() { # jq arguments: updates the state file atomically
  jq "$@" "${ROT_STATE}" > "${ROT_STATE}.new" && chmod 644 "${ROT_STATE}.new" && mv -f "${ROT_STATE}.new" "${ROT_STATE}"
}

# ---------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------
SCENARIOS=()
load_scenarios() {
  local dir f name
  for dir in "${SCRIPT_DIR}/rotation" "${PKI_ROTATE_SCENARIO_DIR:-}"; do
    [[ -n "${dir}" && -d "${dir}" ]] || continue
    # test hook: PKI_ROTATE_BUILTIN_SCENARIOS=0 leaves out the scenarios of rotation/ (the state machine tests use their own)
    [[ "${dir}" == "${SCRIPT_DIR}/rotation" && "${PKI_ROTATE_BUILTIN_SCENARIOS:-1}" == "0" ]] && continue
    for f in "${dir}"/*.sh; do
      [[ -f "${f}" ]] || continue
      name="$(basename "${f}" .sh)"
      [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] || { log "WARNING: ${f}: not a scenario name, skipped"; continue; }
      # shellcheck disable=SC1090
      source "${f}"
      SCENARIOS+=("${name}")
    done
  done
}
fn() { echo "${1//-/_}_$2"; } # scenario function name
scn() { local f; f="$(fn "$1" "$2")"; shift 2; "${f}" "$@"; } # call a scenario function
scn_has() { declare -F "$(fn "$1" "$2")" > /dev/null; }

# ---------------------------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------------------------
# The arguments of the coverage check come from the scenario (`<n>_coverage_args <step>`: --issued-before EPOCH or
# --issuer ALIAS, see rotation-coverage.sh)
coverage_cmd() { echo "${PKI_ROTATE_COVERAGE_CMD:-${SCRIPT_DIR}/rotation-coverage.sh}"; }
coverage_args() { scn_has "$1" coverage_args && scn "$1" coverage_args "$2"; return 0; }
coverage_stragglers() { # scenario step: prints the number of active users that are still on the old side
  local cmd n args
  cmd="$(coverage_cmd)"
  args="$(coverage_args "$1" "$2")"
  [[ -x "${cmd}" ]] || { log "the coverage check ${cmd} is not available: the coverage gate stays closed"; echo unknown; return 0; }
  # shellcheck disable=SC2086
  n="$("${cmd}" ${args} 2> /dev/null)" || { log "the coverage check failed: the coverage gate stays closed"; echo unknown; return 0; }
  [[ "${n}" =~ ^[0-9]+$ ]] && echo "${n}" || echo unknown
}
# Tells a human who has not enrolled again: the table goes to the log and to the alert topic (SNS). Not more than once
# a week for the same set of users, so a rotation that waits does not fill an inbox.
report_stragglers() { # scenario step
  local s="$1" step="$2" cmd args json digest last old t deadline msg subject count unknown topic="${PKI_ALERT_TOPIC_ARN:-}"
  cmd="$(coverage_cmd)"
  [[ -x "${cmd}" ]] || return 0
  args="$(coverage_args "${s}" "${step}")"
  # shellcheck disable=SC2086
  json="$("${cmd}" ${args} --json 2> /dev/null)" || return 0
  digest="$(jq -c '[.users[] | [.kind, .user]]' <<< "${json}" | sha256sum | cut -c1-16)"
  t="$(now)"
  last="$(st_get '.active.coverageReport.at // 0')"
  old="$(st_get '.active.coverageReport.digest // ""')"
  if [[ "${digest}" == "${old}" ]] && (( t - last < 7 * DAY )); then return 0; fi
  count="$(jq -r '.stragglers' <<< "${json}")"
  unknown="$(jq -r '.unknown' <<< "${json}")"
  deadline=""
  scn_has "${s}" deadline && deadline="$(scn "${s}" deadline "${step}")"
  msg="The rotation '${s}' waits at step '${step}' for ${count} active user(s) who are still on the old certificates.
Active means connected now or seen in the last $(jq -r '.activeDays' <<< "${json}") days. Each of them has to enroll again (the QR code of the enrolment portal) so that the phone gets the new chain.
$([[ "${deadline}" =~ ^[0-9]+$ ]] && echo "The step runs when all of them have enrolled again, or on $(fmt_date "${deadline}") at the latest, whoever is left then loses access." || echo "The step runs when all of them have enrolled again.")

$("${cmd}" ${args} --list 2> /dev/null)

'unknown' users connect with a certificate that TAK Server did not issue through enrolment (a data package made by hand): the check cannot see their chain, and they do not hold the rotation back (${unknown} now). Check them by hand."
  subject="TAK.NZ ${PKI_ENV_LABEL:-} rotation ${s}: ${count} user(s) must enroll again"
  log "coverage: ${count} active user(s) are still on the old side (${unknown} unknown):"
  echo "${msg}" | sed 's/^/    /'
  if [[ -n "${topic}" ]]; then
    aws sns publish --topic-arn "${topic}" --subject "${subject:0:100}" --message "${msg}" > /dev/null 2>&1 \
      && log "the list was sent to the alert topic" || log "WARNING: could not publish the list to the alert topic"
  fi
  st_set --argjson t "${t}" --arg d "${digest}" --argjson c "${count}" '.active.coverageReport = {at: $t, digest: $d, count: $c}'
}
# When the task that runs this started: the age of the container's first process, or PKI_ROTATE_TASK_STARTED (tests)
task_started() {
  [[ "${PKI_ROTATE_TASK_STARTED:-}" =~ ^[0-9]+$ ]] && { echo "${PKI_ROTATE_TASK_STARTED}"; return 0; }
  local age
  age="$(ps -o etimes= -p 1 2> /dev/null | tr -d ' ')"
  [[ "${age}" =~ ^[0-9]+$ ]] && echo $(( $(date +%s) - age )) || echo 0
}
# Sets GATE_OUT to "open" or "waiting:<window|coverage|approval>[:<epoch the window opens>]", and GATE_PAST_WINDOW=1
# when the window is over (so waiting for coverage or approval is a stuck rotation, not a normal wait). Not run in
# a subshell: the variables are the result.
gate_status() { # scenario step
  local s="$1" step="$2" gates deadline base opens n t
  t="$(now)"
  GATE_PAST_WINDOW=0
  GATE_OUT=open
  gates=" $(scn "${s}" gate "${step}") "
  [[ "${REQUIRE_APPROVAL}" == *",${step},"* ]] && gates+=" approval "
  deadline=""
  scn_has "${s}" deadline && deadline="$(scn "${s}" deadline "${step}")"
  local pastdeadline=0
  [[ "${deadline}" =~ ^[0-9]+$ ]] && (( t >= deadline )) && pastdeadline=1
  if [[ "${gates}" == *" restart "* ]]; then
    base="$(st_get '.active.lastDoneAt')"
    if (( "$(task_started)" <= base )); then
      # a restart takes minutes; a rotation that waits for two days is stuck (the deployment failed)
      (( t - base > 2 * DAY )) && GATE_PAST_WINDOW=1
      GATE_OUT="waiting:restart"; return 0
    fi
  fi
  if [[ "${gates}" == *" window "* ]] && (( ! pastdeadline )); then
    base="$(st_get '.active.lastDoneAt')"
    opens=$(( base + WINDOW_DAYS * DAY ))
    if (( t < opens )); then GATE_OUT="waiting:window:${opens}"; return 0; fi
  fi
  GATE_PAST_WINDOW=1
  if [[ "${gates}" == *" coverage "* ]] && (( ! pastdeadline )); then
    n="$(coverage_stragglers "${s}" "${step}")"
    if [[ "${n}" != "0" ]]; then
      if [[ "${n}" =~ ^[0-9]+$ ]]; then
        "${METRICS}" emit RotationCoverageStragglers "${n}" || true
        report_stragglers "${s}" "${step}" || true
      fi
      GATE_OUT="waiting:coverage"; return 0
    fi
  fi
  if [[ "${gates}" == *" approval "* && ! -e "${APPROVAL_DIR}/${s}.${step}" ]]; then GATE_OUT="waiting:approval"; fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# The state machine
# ---------------------------------------------------------------------------------------------
begin_rotation() { # scenario
  local s="$1" steps t
  t="$(now)"
  steps="$(scn "${s}" steps | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s -c .)"
  [[ "${steps}" != "[]" ]] || { log "ERROR: scenario ${s} has no steps"; return 1; }
  st_set --arg s "${s}" --argjson steps "${steps}" --argjson t "${t}" \
    '.active = {scenario: $s, steps: $steps, index: 0, status: "pending", startedAt: $t, lastDoneAt: $t, attempts: 0, completed: [], waitingFor: null}'
  log "rotation ${s} started: $(jq -r '.active.steps | join(" -> ")' "${ROT_STATE}")"
}
finish_rotation() { # result
  local t
  t="$(now)"
  st_set --arg result "$1" --argjson t "${t}" '.history += [{scenario: .active.scenario, startedAt: .active.startedAt, finishedAt: $t, result: $result, completed: .active.completed}] | .active = null'
  log "rotation finished: $1"
}
# Runs the steps whose gates are open. Sets RESTART_PENDING=1 when a step asked for a restart. Returns 1 when
# a step failed.
advance() {
  local s step index total rc t
  while [[ "$(st_get '.active != null')" == "true" ]]; do
    s="$(st_get '.active.scenario')"
    index="$(st_get '.active.index')"
    total="$(st_get '.active.steps | length')"
    if (( index >= total )); then
      scn_has "${s}" finished && scn "${s}" finished || true
      finish_rotation done
      return 0
    fi
    step="$(st_get ".active.steps[${index}]")"
    if [[ "$(st_get '.active.status')" == "running" ]]; then
      log "WARNING: step ${step} of ${s} was interrupted: running it again"
    fi
    gate_status "${s}" "${step}"
    if [[ "${GATE_OUT}" != "open" ]]; then
      st_set --arg k "$(cut -d: -f2 <<< "${GATE_OUT}")" '.active.waitingFor = $k'
      log "${s}: step ${step} waits for ${GATE_OUT#waiting:}"
      (( GATE_PAST_WINDOW )) && WAITING_STUCK=1
      return 0
    fi
    st_set --argjson t "$(now)" '.active.status = "running" | .active.stepStartedAt = $t | .active.waitingFor = null'
    log "${s}: running step ${step}"
    rc=0
    scn "${s}" run "${step}" || rc=$?
    if (( rc != 0 && rc != 10 )); then
      st_set '.active.status = "pending" | .active.attempts += 1'
      log "ERROR: step ${step} of ${s} failed (status ${rc}); it is retried at the next run"
      "${METRICS}" emit RotationStepFailed 1 || true
      return 1
    fi
    t="$(now)"
    st_set --arg step "${step}" --argjson t "${t}" \
      '.active.completed += [{step: $step, at: $t}] | .active.index += 1 | .active.status = "pending" | .active.lastDoneAt = $t | .active.attempts = 0 | .active.waitingFor = null'
    rm -f "${APPROVAL_DIR}/${s}.${step}"
    (( rc == 10 )) && RESTART_PENDING=1
  done
  return 0
}

run_locked() {
  RESTART_PENDING=0
  WAITING_STUCK=0
  local s failed=0
  st_init || { log "ERROR: cannot write ${ROT_STATE}"; return 1; }
  if [[ "$(st_get '.active != null')" == "false" ]]; then
    for s in "${SCENARIOS[@]}"; do
      if scn "${s}" due; then
        begin_rotation "${s}" || return 1
        break
      fi
    done
  fi
  advance || failed=1
  # every Enrollment CA has a CRL (a new generation gets an empty one); TAK Server loads it at its next start
  local crc=0
  trust_ensure_manifest && { crl_ensure_all || crc=$?; }
  (( crc == 10 )) && RESTART_PENDING=1
  (( crc == 1 )) && { log "WARNING: not every Enrollment CA has a CRL (see above)"; "${METRICS}" emit RotationStepFailed 1 || true; }
  if (( RESTART_PENDING )); then
    trigger_deployment || { log "ERROR: the rolling deployment could not be started: TAK Server loads the new trust only at its next restart"; "${METRICS}" emit RotationStepFailed 1 || true; failed=1; }
  fi
  "${METRICS}" emit RotationWaiting "${WAITING_STUCK}" || true
  return "${failed}"
}

# ---------------------------------------------------------------------------------------------
# Checks that raise alarms
# ---------------------------------------------------------------------------------------------
spare_keys() { # tier -> 0 when a key generation exists after the one in use
  local tier="$1" in_use slot n found=1
  in_use="$(jq -r ".numbers.${tier}" "${STATE_FILE}")"
  while IFS= read -r slot; do
    [[ "${slot}" =~ ^${tier}-ca-([0-9]+)= ]] || continue
    n=$(( 10#${BASH_REMATCH[1]} ))
    (( n > in_use )) && found=0
  done < <(tr ',' '\n' <<< "${PKI_KMS_CA_KEYS}")
  return "${found}"
}
check_spare_keys() {
  local tier
  for tier in root intermediate; do
    if spare_keys "${tier}"; then
      "${METRICS}" emit RotationSpareKeyMissing 0 Tier="${tier}" || true
    else
      log "WARNING: no spare ${tier} CA key generation: add the next number to pki.kmsCa.${tier}CaNumbers (a CDK deploy creates the key) before it is needed"
      "${METRICS}" emit RotationSpareKeyMissing 1 Tier="${tier}" || true
    fi
  done
}

# ---------------------------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------------------------
plan() { # [--at DATE] [--json]
  local at="" json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --at) at="$(date -u -d "${2:?--at needs a date}" +%s)" || die "cannot read the date '${2}'"; shift ;;
      --json) json=1 ;;
      *) echo "usage: ${0##*/} plan [--at DATE] [--json]" >&2; exit 64 ;;
    esac
    shift
  done
  [[ -n "${at}" ]] && PKI_ROTATION_NOW="${at}"
  local t rows="[]" row
  t="$(now)"
  add_row() { # layer current expires trigger note
    row="$(jq -n --arg layer "$1" --arg current "$2" --argjson expires "${3}" --arg trigger "$4" --arg note "$5" --argjson now "${t}" \
      '{layer: $layer, current: $current, expires: $expires, trigger: (if $trigger == "-" then null else ($trigger | tonumber) end), note: $note}
       | .status = (if .trigger == null then "-" elif .trigger <= $now then "due" else "waiting" end)')"
    rows="$(jq -c ". + [${row}]" <<< "${rows}")"
  }
  local f="${FILES_DIR}" e
  e="$(cert_enddate "${f}/takserver.pem")"; add_row "Server certificate" "$(jq -r .names.serverCn "${STATE_FILE}")" "${e}" "$(( e - SERVER_RENEW * DAY ))" "automatic, ${SERVER_RENEW} days before expiry (#131)"
  e="$(cert_enddate "${f}/admin.pem")"; add_row "Admin certificate" "CN=admin" "${e}" "$(( e - ADMIN_RENEW * DAY ))" "automatic, ${ADMIN_RENEW} days before expiry (#132)"
  e="$(cert_enddate "${f}/enrollment-ca.pem")"
  add_row "Enrollment CA" "$(jq -r .names.enrollment "${STATE_FILE}")" "${e}" "$(( $(cert_startdate "${f}/enrollment-ca.pem") + CL_ROTATION_DAYS * DAY ))" "age ${CL_ROTATION_DAYS} days; $(scenario_note enrollment '#135')"
  e="$(cert_enddate "${f}/intermediate-ca.pem")"
  add_row "Intermediate CA" "$(jq -r .names.intermediate "${STATE_FILE}")" "${e}" "$(( e - (2 * WINDOW_DAYS + 365) * DAY ))" "expiry - (2 x W + 365 days); $(scenario_note intermediate '#172')"
  e="$(cert_enddate "${f}/root-ca.pem")"
  add_row "Root CA" "$(jq -r .names.root "${STATE_FILE}")" "${e}" "$(( e - (WINDOW_DAYS + 365) * DAY ))" "expiry - (W + 365 days); $(scenario_note root '#169')"
  local active spare_root=ok spare_inter=ok
  spare_keys root || spare_root=MISSING
  spare_keys intermediate || spare_inter=MISSING
  active="$(jq -c '.active' "${ROT_STATE}" 2> /dev/null || echo null)"
  if (( json )); then
    jq -n --argjson rows "${rows}" --argjson active "${active:-null}" --argjson now "${t}" --argjson w "${WINDOW_DAYS}" --arg sr "${spare_root}" --arg si "${spare_inter}" \
      '{now: $now, windowDays: $w, layers: $rows, spareKeys: {root: $sr, intermediate: $si}, active: $active}'
    return 0
  fi
  echo "PKI rotation plan for $(fmt_date "${t}")  (W = ${WINDOW_DAYS} days = client certificate ${CLIENT_DAYS} + buffer ${BUFFER_DAYS})"
  printf '%-20s %-32s %-11s %-11s %-8s %s\n' Layer Current Expires Trigger Status Note
  jq -r '.[] | [.layer, .current, (.expires|tostring), (.trigger // "-"|tostring), .status, .note] | @tsv' <<< "${rows}" | while IFS=$'\t' read -r layer cur exp trig status note; do
    printf '%-20s %-32s %-11s %-11s %-8s %s\n' "${layer}" "${cur:0:32}" "$(fmt_date "${exp}")" "$(fmt_date "${trig}")" "${status}" "${note}"
  done
  echo "Spare key generations: Root CA ${spare_root}, Intermediate CA ${spare_inter}$([[ "${spare_root}${spare_inter}" == *MISSING* ]] && echo ' (add the next number to pki.kmsCa.<tier>CaNumbers; a CDK deploy creates the key)')"
  if [[ "${active}" == "null" || -z "${active}" ]]; then
    echo "Active rotation: none"
  else
    echo "Active rotation: $(jq -r '.scenario' <<< "${active}"), step $(jq -r '.steps[.index] // "(finished)"' <<< "${active}") of: $(jq -r '.steps | join(" -> ")' <<< "${active}")"
    local s step
    s="$(jq -r .scenario <<< "${active}")"
    step="$(jq -r '.steps[.index] // empty' <<< "${active}")"
    if [[ -n "${step}" ]] && scn_has "${s}" gate; then
      echo "  gates of this step: $(scn "${s}" gate "${step}")$([[ "${REQUIRE_APPROVAL}" == *",${step},"* ]] && echo ' approval'); window opens $(fmt_date "$(( $(jq -r .lastDoneAt <<< "${active}") + WINDOW_DAYS * DAY ))")"
    fi
  fi
}
scenario_note() { # name ticket
  local n
  for n in "${SCENARIOS[@]}"; do [[ "${n}" == "$1" ]] && { echo "orchestrated rotation"; return 0; }; done
  echo "orchestrated rotation not built yet (${2})"
}

# ---------------------------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  case "${cmd}" in run | plan | status | approve | abort) ;; *) echo "usage: ${0##*/} run|plan [--at DATE] [--json]|status|approve <scenario> <step>|abort" >&2; exit 64 ;; esac
  shift
  if [[ -z "${PKI_KMS_CA_KEYS:-}" || ! -f "${STATE_FILE}" ]]; then
    log "rotation: not applicable (no first-boot PKI on this stack)"
    exit 0
  fi
  load_settings
  load_rotation_settings
  load_scenarios
  case "${cmd}" in
    run)
      local leaf rc=0 failed=0 leaves
      # the server certificate last: its rotation ends in a rolling deployment that replaces this task
      if [[ -n "${PKI_ROTATE_LEAF_SCRIPTS:-}" ]]; then
        read -ra leaves <<< "${PKI_ROTATE_LEAF_SCRIPTS}"
      else
        leaves=("${SCRIPT_DIR}/admin-cert-rotate.sh" "${SCRIPT_DIR}/server-cert-rotate.sh")
      fi
      for leaf in "${leaves[@]}"; do
        # a failing leaf rotation is reported by that script (its own metric); the rest still runs
        "${leaf}" check || log "WARNING: ${leaf##*/} check failed (status $?)"
      done
      CLUSTER_LOCK_WAIT="${CLUSTER_LOCK_WAIT:-900}"
      with_cluster_lock "${LOCK_NAME}" run_locked || rc=$?
      check_spare_keys
      exit "${rc}"
      ;;
    plan) st_init; plan "$@" ;;
    status)
      st_init
      echo "State file ${ROT_STATE}:"
      jq . "${ROT_STATE}"
      if [[ "$(st_get '.active != null')" == "true" ]]; then
        echo "Waiting for: $(st_get '.active.waitingFor // "nothing (the next run starts the step)"')"
      fi
      ls "${APPROVAL_DIR}" 2> /dev/null | sed 's/^/approved: /'
      ;;
    approve)
      [[ $# -eq 2 && "$1" =~ ^[a-z][a-z0-9-]*$ && "$2" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "usage: ${0##*/} approve <scenario> <step>" >&2; exit 64; }
      mkdir -p "${APPROVAL_DIR}" && date -u +%Y-%m-%dT%H:%M:%SZ > "${APPROVAL_DIR}/$1.$2" || die "cannot write the approval"
      log "approved: $1 $2 (it runs at the next daily run)"
      ;;
    abort)
      local rc=0
      st_init
      CLUSTER_LOCK_WAIT="${CLUSTER_LOCK_WAIT:-120}"
      with_cluster_lock "${LOCK_NAME}" abort_locked || rc=$?
      exit "${rc}"
      ;;
  esac
}
abort_locked() {
  local s
  [[ "$(st_get '.active != null')" == "true" ]] || { log "no rotation is active"; return 0; }
  s="$(st_get '.active.scenario')"
  if scn_has "${s}" abort; then
    local rc=0
    scn "${s}" abort || rc=$?
    # 2: the scenario cannot be undone any more (it is past the point of no return): the rotation stays active
    (( rc == 2 )) && { log "the rotation ${s} cannot be aborted any more: it stays active"; return 2; }
    (( rc == 0 )) || log "WARNING: ${s} could not undo everything"
  fi
  finish_rotation aborted
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
