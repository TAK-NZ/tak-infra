#!/bin/bash
# Tests for docker-container/scripts/pki-rotate.sh, the rotation orchestrator (#171).
#
# Same set-up as the other PKI tests (test/KmsCa/pki-harness.sh). The state machine is tested with a scenario
# of its own (`demo`: start, bridge, cut, retire) and with a clock that the test moves (PKI_ROTATION_NOW), so a
# window of 455 days takes a moment. `plan` runs against a PKI built by pki-bootstrap.sh.
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-pki-rotate.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
ROT="${REPO_ROOT}/docker-container/scripts/pki-rotate.sh"
export StackName=TAK-Test ECS_Cluster_Name=test-cluster ECS_Service_Name=test-service CLUSTER_LOCK_POLL=0.2 PKI_ROTATE_RETRY_DELAY=0

# --- stubs: leaf scripts, coverage check, a scenario ----------------------------------------
cat > "${WORK}/leaf.sh" <<'EOF'
#!/bin/bash
echo "$(basename "$0") $*" >> "${STUB_LOG}/leaf.log"
[[ -e "${STUB_LOG}/leaf-fails" && "$(basename "$0")" == leaf1.sh ]] && exit 1
exit 0
EOF
cp "${WORK}/leaf.sh" "${WORK}/leaf1.sh"; cp "${WORK}/leaf.sh" "${WORK}/leaf2.sh"; chmod +x "${WORK}/leaf1.sh" "${WORK}/leaf2.sh"
cat > "${WORK}/coverage.sh" <<'EOF'
#!/bin/bash
cat "${STUB_LOG}/coverage.count" 2> /dev/null || echo 0
EOF
chmod +x "${WORK}/coverage.sh"
mkdir -p "${WORK}/scenarios"
cat > "${WORK}/scenarios/demo.sh" <<'EOF'
# a test scenario for the orchestrator
demo_summary() { echo "demo"; }
demo_due() { [[ -e "${STUB_LOG}/demo-due" ]]; }
demo_steps() { echo "start bridge cut retire"; }
demo_gate() { case "$1" in start) echo none ;; bridge) echo window ;; cut) echo "window coverage" ;; retire) echo window ;; esac; }
demo_deadline() { [[ -f "${STUB_LOG}/demo-deadline-$1" ]] && cat "${STUB_LOG}/demo-deadline-$1"; return 0; }
demo_run() {
  echo "run $1 at $(now)" >> "${STUB_LOG}/demo.log"
  if [[ -e "${STUB_LOG}/demo-fail-$1" ]]; then rm -f "${STUB_LOG}/demo-fail-$1"; return 1; fi
  [[ "$1" == bridge ]] && return 10
  return 0
}
demo_finished() { echo "finished" >> "${STUB_LOG}/demo.log"; }
demo_abort() { echo "abort" >> "${STUB_LOG}/demo.log"; }
EOF

export PKI_ROTATE_SCENARIO_DIR="${WORK}/scenarios" PKI_ROTATE_LEAF_SCRIPTS="${WORK}/leaf1.sh ${WORK}/leaf2.sh" PKI_ROTATE_COVERAGE_CMD="${WORK}/coverage.sh"
new_stack() { fresh "$1"; shift; env "$@" "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 || { echo "bootstrap failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }; }
orch() { # epoch [env assignments...] -> exit status; output in run.log
  local at="$1"
  shift
  env PKI_ROTATION_NOW="${at}" PKI_ROTATE_SCENARIO_DIR="${WORK}/scenarios" PKI_ROTATE_LEAF_SCRIPTS="${WORK}/leaf1.sh ${WORK}/leaf2.sh" \
    PKI_ROTATE_COVERAGE_CMD="${WORK}/coverage.sh" "$@" "${ROT}" run > "${WORK}/run.log" 2>&1
  echo $?
}
reset_log() { : > "${STUB_LOG}/metrics.log"; : > "${STUB_LOG}/ecs.log"; : > "${STUB_LOG}/demo.log"; : > "${STUB_LOG}/leaf.log"; find "${STUB_LOG}" -maxdepth 1 -name 'demo-*' -delete; echo 0 > "${STUB_LOG}/coverage.count"; }
metric_count() { grep -c -- "--metric-name $1 " "${STUB_LOG}/metrics.log"; }
metric_last() { grep -- "--metric-name $1 " "${STUB_LOG}/metrics.log" | tail -1 | sed 's/.*--value \([^ ]*\).*/\1/'; }
state() { jq -r "$1" "${FILES}/rotation-state.json"; }
W=$(( 455 * 86400 ))
T0=1800000000

echo "not applicable"
fresh na
assert_eq "no state file: exit 0" "$(orch ${T0})" "0"
assert_contains "it says so" "$(cat "${WORK}/run.log")" "not applicable"
"${ROT}" bogus > /dev/null 2>&1; assert_eq "an unknown command is refused" "$?" "64"

echo "setup: a first-boot PKI"
new_stack main PKI_SERVER_CERT_DAYS=365
reset_log

echo "daily run without a rotation"
assert_eq "run: exit 0" "$(orch ${T0})" "0"
assert_eq "the leaf scripts ran in order: admin first, then server (here leaf1 then leaf2), each with check" "$(tr '\n' ',' < "${STUB_LOG}/leaf.log")" "leaf1.sh check,leaf2.sh check,"
assert_eq "the state file exists, nothing active" "$(state '.active')/$(state '.version')" "null/1"
assert_eq "RotationWaiting is emitted as 0" "$(metric_last RotationWaiting)" "0"
: > "${STUB_LOG}/leaf.log"
touch "${STUB_LOG}/leaf-fails"
assert_eq "a failing leaf script does not stop the run: exit 0" "$(orch ${T0})" "0"
assert_eq "...and the second one still ran" "$(tr '\n' ',' < "${STUB_LOG}/leaf.log")" "leaf1.sh check,leaf2.sh check,"
assert_contains "...and it is logged" "$(cat "${WORK}/run.log")" "leaf1.sh check failed"
rm -f "${STUB_LOG}/leaf-fails"

echo "a rotation through its gates, with the clock moved by the test"
reset_log
touch "${STUB_LOG}/demo-due"
assert_eq "T0: the rotation is due and starts; step start has no gate" "$(orch ${T0})" "0"
assert_eq "the first step ran" "$(cat "${STUB_LOG}/demo.log")" "run start at ${T0}"
assert_eq "active: demo, index 1 (bridge), waiting for the window" "$(state '.active.scenario')/$(state '.active.index')/$(state '.active.waitingFor')" "demo/1/window"
assert_eq "no restart yet" "$(wc -l < "${STUB_LOG}/ecs.log")" "0"
rm -f "${STUB_LOG}/demo-due"
assert_eq "T0 + W - 1 day: still waiting" "$(orch $(( T0 + W - 86400 )))" "0"
assert_eq "no step ran" "$(wc -l < "${STUB_LOG}/demo.log")" "1"
assert_contains "the log says what it waits for" "$(cat "${WORK}/run.log")" "waits for window"
assert_eq "waiting for the window is not a stuck rotation: RotationWaiting 0" "$(metric_last RotationWaiting)" "0"
assert_eq "T0 + W: bridge runs" "$(orch $(( T0 + W )))" "0"
assert_eq "bridge ran" "$(tail -1 "${STUB_LOG}/demo.log")" "run bridge at $(( T0 + W ))"
assert_eq "bridge asked for a restart: one rolling deployment" "$(grep -c 'ecs update-service' "${STUB_LOG}/aws.log")/$(wc -l < "${STUB_LOG}/ecs.log")" "$(grep -c 'ecs update-service' "${STUB_LOG}/aws.log")/1"
assert_eq "next step cut waits for a new window, counted from the end of bridge" "$(state '.active.index')/$(state '.active.waitingFor')/$(state '.active.lastDoneAt')" "2/window/$(( T0 + W ))"
assert_eq "T0 + 2W - 1 day: still waiting, no second restart" "$(orch $(( T0 + 2 * W - 86400 )))/$(wc -l < "${STUB_LOG}/ecs.log")" "0/1"
echo 3 > "${STUB_LOG}/coverage.count"
assert_eq "T0 + 2W with 3 users not covered: waits for coverage" "$(orch $(( T0 + 2 * W )))" "0"
assert_eq "cut did not run" "$(tail -1 "${STUB_LOG}/demo.log")" "run bridge at $(( T0 + W ))"
assert_eq "waiting for: coverage" "$(state '.active.waitingFor')" "coverage"
assert_eq "RotationCoverageStragglers is emitted with the number" "$(metric_last RotationCoverageStragglers)" "3"
assert_eq "the window is over, so this is a stuck rotation: RotationWaiting 1" "$(metric_last RotationWaiting)" "1"
echo 0 > "${STUB_LOG}/coverage.count"
assert_eq "coverage is complete: cut runs" "$(orch $(( T0 + 2 * W + 86400 )))" "0"
assert_eq "cut ran" "$(tail -1 "${STUB_LOG}/demo.log")" "run cut at $(( T0 + 2 * W + 86400 ))"
assert_eq "retire needs an approval (default) and the window: waits for the window first" "$(state '.active.index')/$(state '.active.waitingFor')" "3/window"
assert_eq "T0 + 3W + 1 day: the window is over, no approval: waits for approval" "$(orch $(( T0 + 3 * W + 2 * 86400 )))" "0"
assert_eq "waiting for: approval" "$(state '.active.waitingFor')" "approval"
assert_eq "...and RotationWaiting is 1 (a human must act)" "$(metric_last RotationWaiting)" "1"
assert_eq "retire did not run" "$(grep -c 'run retire' "${STUB_LOG}/demo.log")" "0"
assert_eq "approve" "$(env PKI_ROTATION_NOW=$(( T0 + 3 * W + 2 * 86400 )) PKI_ROTATE_SCENARIO_DIR="${WORK}/scenarios" "${ROT}" approve demo retire > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "T0 + 3W + 2 days: retire runs, the rotation finishes" "$(orch $(( T0 + 3 * W + 3 * 86400 )))" "0"
assert_eq "retire ran, then the scenario's finished hook" "$(tail -2 "${STUB_LOG}/demo.log" | tr '\n' ',')" "run retire at $(( T0 + 3 * W + 3 * 86400 )),finished,"
assert_eq "no active rotation; one history entry: done, all four steps" "$(state '.active')/$(state '.history | length')/$(state '.history[0].result')/$(state '.history[0].completed | length')" "null/1/done/4"
assert_eq "the approval is used up" "$(ls "${FILES}/.rotation-approvals" 2> /dev/null | wc -l)" "0"
assert_eq "RotationWaiting is back to 0" "$(metric_last RotationWaiting)" "0"
assert_eq "exactly one restart in the whole rotation (the bridge step)" "$(wc -l < "${STUB_LOG}/ecs.log")" "1"

echo "approval is optional"
reset_log
touch "${STUB_LOG}/demo-due"
orch ${T0} PKI_ROTATION_REQUIRE_APPROVAL= > /dev/null
rm -f "${STUB_LOG}/demo-due"
orch $(( T0 + W )) PKI_ROTATION_REQUIRE_APPROVAL= > /dev/null
orch $(( T0 + 2 * W )) PKI_ROTATION_REQUIRE_APPROVAL= > /dev/null
assert_eq "no approval required (the setting is empty): retire runs by itself at the third window" "$(orch $(( T0 + 3 * W )) PKI_ROTATION_REQUIRE_APPROVAL=)/$(tail -2 "${STUB_LOG}/demo.log" | head -1)" "0/run retire at $(( T0 + 3 * W ))"
echo "an approval can also be required for another step"
reset_log
touch "${STUB_LOG}/demo-due"
orch ${T0} PKI_ROTATION_REQUIRE_APPROVAL=bridge > /dev/null
rm -f "${STUB_LOG}/demo-due"
orch $(( T0 + W )) PKI_ROTATION_REQUIRE_APPROVAL=bridge > /dev/null
assert_eq "bridge waits for its approval" "$(state '.active.waitingFor')/$(grep -c 'run bridge' "${STUB_LOG}/demo.log")" "approval/0"
"${ROT}" abort > "${WORK}/run.log" 2>&1
assert_eq "abort: the scenario's hook ran and the rotation is in the history as aborted" "$(tail -1 "${STUB_LOG}/demo.log")/$(state '.active')/$(state '.history[-1].result')" "abort/null/aborted"
assert_eq "abort without an active rotation is fine" "$("${ROT}" abort > "${WORK}/run.log" 2>&1; echo $?)" "0"

echo "a hard deadline opens the window and the coverage gate, not the approval"
reset_log
touch "${STUB_LOG}/demo-due"
orch ${T0} > /dev/null
rm -f "${STUB_LOG}/demo-due"
echo $(( T0 + 100 )) > "${STUB_LOG}/demo-deadline-bridge"
echo 7 > "${STUB_LOG}/coverage.count"
assert_eq "before the deadline the window is closed" "$(orch $(( T0 + 50 )))/$(grep -c 'run bridge' "${STUB_LOG}/demo.log")" "0/0"
assert_eq "at the deadline bridge runs although the window is not over" "$(orch $(( T0 + 100 )))/$(grep -c 'run bridge' "${STUB_LOG}/demo.log")" "0/1"
echo $(( T0 + 200 )) > "${STUB_LOG}/demo-deadline-cut"
assert_eq "cut: before its deadline the window is closed" "$(orch $(( T0 + 150 )))/$(grep -c 'run cut' "${STUB_LOG}/demo.log")" "0/0"
assert_eq "cut at its deadline: runs although 7 users are not covered" "$(orch $(( T0 + 200 )))/$(grep -c 'run cut' "${STUB_LOG}/demo.log")" "0/1"
echo $(( T0 + 300 )) > "${STUB_LOG}/demo-deadline-retire"
assert_eq "retire at its deadline still needs the approval" "$(orch $(( T0 + 300 )))/$(state '.active.waitingFor')/$(grep -c 'run retire' "${STUB_LOG}/demo.log")" "0/approval/0"
assert_eq "...and that is a stuck rotation" "$(metric_last RotationWaiting)" "1"
"${ROT}" abort > /dev/null 2>&1

echo "a failing step is retried at the next run"
reset_log
touch "${STUB_LOG}/demo-due" "${STUB_LOG}/demo-fail-start"
assert_eq "the first step fails: exit 1" "$(orch ${T0})" "1"
assert_eq "RotationStepFailed emitted" "$(metric_count RotationStepFailed)" "1"
assert_eq "the state: step 0, attempt 1, pending" "$(state '.active.index')/$(state '.active.attempts')/$(state '.active.status')" "0/1/pending"
rm -f "${STUB_LOG}/demo-due"
assert_eq "the next run retries it and goes on" "$(orch $(( T0 + 86400 )))" "0"
assert_eq "the step ran twice, the rotation moved to the next step, attempts reset" "$(grep -c 'run start' "${STUB_LOG}/demo.log")/$(state '.active.index')/$(state '.active.attempts')" "2/1/0"
"${ROT}" abort > /dev/null 2>&1

echo "a step that was interrupted runs again"
reset_log
touch "${STUB_LOG}/demo-due"
orch ${T0} > /dev/null
rm -f "${STUB_LOG}/demo-due"
jq '.active.status = "running"' "${FILES}/rotation-state.json" > "${WORK}/s.json" && cp "${WORK}/s.json" "${FILES}/rotation-state.json"
orch $(( T0 + W )) > /dev/null
assert_contains "the log says so" "$(cat "${WORK}/run.log")" "was interrupted: running it again"
assert_eq "...and bridge ran" "$(grep -c 'run bridge' "${STUB_LOG}/demo.log")" "1"
"${ROT}" abort > /dev/null 2>&1

echo "the restart is requested after the state is saved, and a failing deployment is reported"
reset_log
touch "${STUB_LOG}/demo-due"
orch ${T0} > /dev/null
rm -f "${STUB_LOG}/demo-due"
assert_eq "bridge with a deployment that fails: exit 1" "$(orch $(( T0 + W )) STUB_ECS_FAILS=1)" "1"
assert_eq "...the step is recorded as done anyway (the state was saved first)" "$(state '.active.index')" "2"
assert_eq "...and RotationStepFailed emitted" "$(metric_count RotationStepFailed)" "1"
"${ROT}" abort > /dev/null 2>&1

echo "two nodes run at once"
reset_log
touch "${STUB_LOG}/demo-due"
( orch ${T0} > "${WORK}/rc1" ) &
( env PKI_ROTATION_NOW=${T0} PKI_ROTATE_SCENARIO_DIR="${WORK}/scenarios" PKI_ROTATE_LEAF_SCRIPTS="${WORK}/leaf1.sh" PKI_ROTATE_COVERAGE_CMD="${WORK}/coverage.sh" "${ROT}" run > "${WORK}/run2.log" 2>&1; echo $? > "${WORK}/rc2" ) &
wait
rm -f "${STUB_LOG}/demo-due"
assert_eq "both exit 0" "$(cat "${WORK}/rc1" "${WORK}/rc2" | tr '\n' ' ')" "0 0 "
assert_eq "the first step ran once" "$(grep -c 'run start' "${STUB_LOG}/demo.log")" "1"
"${ROT}" abort > /dev/null 2>&1
echo "another node holds the lock"
mkdir -p "${FILES}/.locks"
printf 'other:1:1:1 60 othernode\n' > "${FILES}/.locks/pki-rotation.lock"
assert_eq "exit 75 after the wait" "$(orch ${T0} CLUSTER_LOCK_WAIT=1)" "75"
find "${FILES}/.locks/pki-rotation.lock" -delete

echo "spare key generations"
reset_log
two="root-ca-01=11111111-1111-4111-8111-111111111111,intermediate-ca-01=22222222-2222-4222-8222-222222222222"
orch ${T0} PKI_KMS_CA_KEYS="${two}" > /dev/null
assert_eq "only generation 1 exists: both tiers report a missing spare" "$(grep -- '--metric-name RotationSpareKeyMissing' "${STUB_LOG}/metrics.log" | sed 's/.*--value \([0-9]*\).*--dimensions \([^ ]*\).*/\1 \2/' | sort | tr '\n' ';')" "1 Stack=TAK-Test,Tier=intermediate;1 Stack=TAK-Test,Tier=root;"
assert_contains "the log tells what to do" "$(cat "${WORK}/run.log")" "add the next number to pki.kmsCa.rootCaNumbers"
reset_log
orch ${T0} PKI_KMS_CA_KEYS="${two},root-ca-02=33333333-3333-4333-8333-333333333333" > /dev/null
assert_eq "a spare Root CA key: root 0, intermediate 1" "$(grep -- '--metric-name RotationSpareKeyMissing' "${STUB_LOG}/metrics.log" | sed 's/.*--value \([0-9]*\).*Tier=\([a-z]*\).*/\2=\1/' | sort | tr '\n' ' ')" "intermediate=1 root=0 "
reset_log
orch ${T0} PKI_KMS_CA_KEYS="${two},root-ca-02=33333333-3333-4333-8333-333333333333,intermediate-ca-02=44444444-4444-4444-8444-444444444444" > /dev/null
assert_eq "spares for both: both 0" "$(grep -- '--metric-name RotationSpareKeyMissing' "${STUB_LOG}/metrics.log" | sed 's/.*--value \([0-9]*\).*Tier=\([a-z]*\).*/\2=\1/' | sort | tr '\n' ' ')" "intermediate=0 root=0 "
jq '.numbers.root = 2' "${FILES}/pki-state.json" > "${WORK}/p.json" && cp "${WORK}/p.json" "${FILES}/pki-state.json"
reset_log
orch ${T0} PKI_KMS_CA_KEYS="${two},root-ca-02=33333333-3333-4333-8333-333333333333,intermediate-ca-02=44444444-4444-4444-8444-444444444444" > /dev/null
assert_eq "after the rotation to Root CA 02 there is no spare left for the root (the alarm years before it is needed)" "$(grep -- '--metric-name RotationSpareKeyMissing' "${STUB_LOG}/metrics.log" | sed 's/.*--value \([0-9]*\).*Tier=\([a-z]*\).*/\2=\1/' | sort | tr '\n' ' ')" "intermediate=0 root=1 "
jq '.numbers.root = 1' "${FILES}/pki-state.json" > "${WORK}/p.json" && cp "${WORK}/p.json" "${FILES}/pki-state.json"

echo "plan"
plan_env() { env PKI_ROTATE_SCENARIO_DIR="${WORK}/scenarios" PKI_KMS_CA_KEYS="${two},root-ca-02=33333333-3333-4333-8333-333333333333,intermediate-ca-02=44444444-4444-4444-8444-444444444444" "$@"; }
before="$(sha256sum "${FILES}/rotation-state.json" "${FILES}/pki-state.json" | cut -c1-16 | tr '\n' ' ')"
plan_env "${ROT}" plan > "${WORK}/plan.txt" 2>&1
assert_eq "plan: exit 0" "$?" "0"
for layer in "Server certificate" "Admin certificate" "Enrollment CA" "Intermediate CA" "Root CA" "Spare key generations" "Active rotation: none"; do
  assert_contains "plan lists: ${layer}" "$(cat "${WORK}/plan.txt")" "${layer}"
done
assert_contains "plan states W" "$(head -1 "${WORK}/plan.txt")" "W = 455 days = client certificate 365 + buffer 90"
assert_eq "plan changes nothing" "$(sha256sum "${FILES}/rotation-state.json" "${FILES}/pki-state.json" | cut -c1-16 | tr '\n' ' ')" "${before}"
plan_env "${ROT}" plan --json > "${WORK}/plan.json" 2> /dev/null
j() { jq -r "$1" "${WORK}/plan.json"; }
end_of() { date -d "$(openssl x509 -in "${FILES}/$1" -noout -enddate | cut -d= -f2)" +%s; }
start_of() { date -d "$(openssl x509 -in "${FILES}/$1" -noout -startdate | cut -d= -f2)" +%s; }
assert_eq "plan --json: five layers" "$(j '.layers | length')" "5"
assert_eq "server certificate: trigger 60 days before expiry" "$(j '.layers[0].trigger')" "$(( $(end_of takserver.pem) - 60 * 86400 ))"
assert_eq "admin certificate: trigger 60 days before expiry" "$(j '.layers[1].trigger')" "$(( $(end_of admin.pem) - 60 * 86400 ))"
assert_eq "Enrollment CA: trigger at the age of 365 days" "$(j '.layers[2].trigger')" "$(( $(start_of enrollment-ca.pem) + 365 * 86400 ))"
assert_eq "Intermediate CA: trigger at expiry - (2 x 455 + 365) days" "$(j '.layers[3].trigger')" "$(( $(end_of intermediate-ca.pem) - (2 * 455 + 365) * 86400 ))"
assert_eq "Root CA: trigger at expiry - (455 + 365) days" "$(j '.layers[4].trigger')" "$(( $(end_of root-ca.pem) - (455 + 365) * 86400 ))"
assert_eq "today nothing is due" "$(j '[.layers[].status] | unique | join(",")')" "waiting"
assert_eq "spare keys are ok" "$(j '.spareKeys.root + "/" + .spareKeys.intermediate')" "ok/ok"
plan_env "${ROT}" plan --at "$(date -u -d '+400 days' +%Y-%m-%d)" --json > "${WORK}/plan.json" 2> /dev/null
assert_eq "plan --at in 400 days: the leaf certificates (365 days) and the Enrollment CA (age 365) are due, the CAs above are not" "$(j '[.layers[] | select(.status == "due") | .layer] | join(",")')" "Server certificate,Admin certificate,Enrollment CA"
plan_env "${ROT}" plan --at "$(date -u -d '+10 years' +%Y-%m-%d)" --json > "${WORK}/plan.json" 2> /dev/null
assert_eq "plan --at in 10 years: everything but the Root CA is due" "$(j '[.layers[] | select(.status == "due") | .layer] | join(",")')" "Server certificate,Admin certificate,Enrollment CA,Intermediate CA"
assert_contains "plan notes that the Enrollment CA rotation is not built yet" "$(cat "${WORK}/plan.txt")" "orchestrated rotation not built yet (#135)"
assert_eq "plan with a bad date: exit 1" "$(plan_env "${ROT}" plan --at nonsense > /dev/null 2>&1; echo $?)" "1"
assert_eq "plan with an unknown option: exit 64" "$(plan_env "${ROT}" plan --bogus > /dev/null 2>&1; echo $?)" "64"
echo "plan shows an active rotation"
touch "${STUB_LOG}/demo-due"
orch ${T0} > /dev/null
rm -f "${STUB_LOG}/demo-due"
plan_env PKI_ROTATION_NOW=${T0} "${ROT}" plan > "${WORK}/plan.txt" 2>&1
assert_contains "the active rotation, its steps and where it is" "$(grep 'Active rotation' "${WORK}/plan.txt")" "demo, step bridge of: start -> bridge -> cut -> retire"
assert_contains "the gate and the day the window opens" "$(cat "${WORK}/plan.txt")" "window opens $(date -u -d "@$(( T0 + W ))" +%Y-%m-%d)"
plan_env "${ROT}" status > "${WORK}/status.txt" 2>&1
assert_contains "status shows the state and what it waits for" "$(cat "${WORK}/status.txt")" "Waiting for: window"
"${ROT}" abort > /dev/null 2>&1

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
