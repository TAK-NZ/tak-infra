#!/bin/bash
# Tests for docker-container/scripts/rotation/enrollment.sh, the rotation of the Enrollment Signing CA (#135).
#
# Same set-up as the other PKI tests (test/KmsCa/pki-harness.sh): SoftHSM2 tokens stand in for the KMS keys, a stub
# `aws` for Secrets Manager (including delete-secret, which logs the recovery window), CloudWatch, ECS and SNS.
# Two more stubs stand in for TAK Server, as in test-admin-cert-rotate.sh: `java` (UserManager.jar) and `curl` (the
# certadmin API). The coverage check is a stub that prints a number from a file. The clock is moved with
# PKI_ROTATION_NOW, the task start with PKI_ROTATE_TASK_STARTED. The scenario runs inside pki-rotate.sh, as in
# the container.
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-rotation-enrollment.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
ROT="${REPO_ROOT}/docker-container/scripts/pki-rotate.sh"
TRUST="${REPO_ROOT}/docker-container/scripts/pki-trust.sh"
export StackName=TAK-Test CLUSTER_LOCK_POLL=0.2 ECS_Cluster_Name=test-cluster ECS_Service_Name=test-service PKI_ROTATE_RETRY_DELAY=0
# --- stubs ---------------------------------------------------------------------------------
cat > "${WORK}/bin/java-stub" <<'EOF'
#!/bin/bash
shift 2
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }
echo "$1 $2 fp=$(fp "$3")" >> "${STUB_LOG}/java.log"
case "$1 $2" in
  "certmod -A") fp "$3" > "${STUB_LOG}/registered"; exit 0 ;;
  "certmod -s") printf "\tUsername:      'admin'\n\tRole:          ROLE_ADMIN\n\tFingerprint:   %s\n" "$(cat "${STUB_LOG}/registered" 2> /dev/null)" >&2; exit 0 ;;
esac
exit 2
EOF
cat > "${WORK}/bin/curl-stub" <<'EOF'
#!/bin/bash
printf '200'
EOF
cat > "${WORK}/leaf.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "${WORK}/coverage.sh" <<'EOF'
#!/bin/bash
echo "$*" >> "${STUB_LOG}/coverage-args.log"
case "$*" in
  *--json*) echo '{"stragglers":0,"unknown":0,"activeDays":30,"users":[]}' ;;
  *--list*) echo "(nobody)" ;;
  *) cat "${STUB_LOG}/coverage.count" 2> /dev/null || echo 0 ;;
esac
EOF
chmod +x "${WORK}/bin/java-stub" "${WORK}/bin/curl-stub" "${WORK}/leaf.sh" "${WORK}/coverage.sh"
export JAVA_BIN="${WORK}/bin/java-stub" CURL_BIN="${WORK}/bin/curl-stub" TAK_USER_MANAGER_JAR=/nonexistent/UserManager.jar
export PKI_ROTATE_LEAF_SCRIPTS="${WORK}/leaf.sh" PKI_ROTATE_COVERAGE_CMD="${WORK}/coverage.sh"
# Rotation every 10 days, W = 20 + 10 = 30 days, Enrollment CA 100 days, Intermediate CA 200 days
export PKI_ROOT_DAYS=400 PKI_INTERMEDIATE_DAYS=200 PKI_ENROLLMENT_CA_DAYS=100 PKI_SERVER_CERT_DAYS=30 PKI_ADMIN_CERT_DAYS=30
export PKI_CLIENT_CERT_DAYS=20 PKI_ROTATION_BUFFER_DAYS=10 PKI_ENROLLMENT_CA_ROTATION_DAYS=10 PKI_ADMIN_CERT_RENEW_DAYS=10
T=$(date +%s)
DAY=86400
at() { echo $(( T + $1 * DAY )); } # epoch of day N of the test
new_stack() { # name
  fresh "$1"
  # a deleted secret keeps its name for the recovery window: every stack has a stack name of its own
  export StackName="TAK-$1"
  SECRET2="${StackName}/TAK-Server/Enrollment-CA-02"; SECRET3="${StackName}/TAK-Server/Enrollment-CA-03"
  "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 \
    || { echo "bootstrap of $1 failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }
  reset_log
  echo 0 > "${STUB_LOG}/coverage.count"
}
reset_log() { local f; for f in metrics ecs aws sns java coverage-args delete; do : > "${STUB_LOG}/${f}.log"; done; }
# run [day] [task-started-day] [env...] -> exit status; output in run.log. The task started at day 'task-started-day' (default: 0)
orch() {
  local day="$1" task="${2:-0}"
  shift 2 2> /dev/null || shift $#
  env PKI_ROTATION_NOW="$(at "${day}")" PKI_ROTATE_TASK_STARTED="$(at "${task}")" PKI_ALERT_TOPIC_ARN="arn:aws:sns:ap-southeast-6:1:alert" "$@" "${ROT}" run > "${WORK}/run.log" 2>&1
  echo $?
}
rot() { env PKI_ROTATION_NOW="$(at "${NOWDAY:-0}")" "${ROT}" "$@" > "${WORK}/run.log" 2>&1; echo $?; }
state() { jq -r "$1" "${FILES}/pki-state.json"; }
rstate() { jq -r "$1" "${FILES}/rotation-state.json"; }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }
aliases() { keytool -list -keystore "$1" -storepass atakatak 2> /dev/null | grep -E 'trustedCertEntry|PrivateKeyEntry' | cut -d, -f1 | sort | tr '\n' ' ' | sed 's/ $//'; }
signing_fp() { openssl pkcs12 -in "${TMPFS}/intermediate-ca-signing.p12" -passin pass:atakatak -clcerts -nokeys 2> /dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }
secret_file() { echo "${STUB_SECRETS}/$(echo "$1" | tr '/:' '__')"; }
metric_count() { grep -c -- "--metric-name $1 " "${STUB_LOG}/metrics.log"; }
ecs_count() { grep -c . "${STUB_LOG}/ecs.log"; }
SERVER_JKS=truststore-intermediate-ca.jks
issuer_ok() { # cert.pem ca.pem
  openssl verify -no_check_time -partial_chain -CAfile "$2" <(openssl x509 -in "$1") > /dev/null 2>&1 && echo yes || echo no
}
no_leftovers() { echo "$(ls "${TMPFS}" | grep -c -e '^enrollment\.' -e '^rotate-admin\.' -e '^tomb\.' -e '^crl-')/$(ls -A "${FILES}" | grep -c -e '\.new$' -e '\.restore$')"; }

echo "a stack that is not due"
new_stack main
OLD_FP="$(fp "${FILES}/enrollment-ca.pem")"
OLD_CN="$(state .names.enrollment)"
assert_eq "day 5: exit 0" "$(orch 5 0)" "0"
assert_eq "day 5: no rotation (the Enrollment CA is 5 days old, the trigger is 10)" "$(rstate '.active')" "null"
assert_eq "the manifest lists one Enrollment CA" "$(state '[.trust.entries[] | select(.alias | startswith("enrollment-ca"))] | length')" "1"
echo "due: create and switch"
assert_eq "day 11: exit 0" "$(orch 11 0)" "0"
assert_contains "the log says it starts" "$(cat "${WORK}/run.log")" "rotation enrollment started: create -> switch -> admin -> retire"
assert_eq "create and switch are done, the admin step waits" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.steps[.active.index]')" "create,switch admin"
assert_eq "it waits for the restart" "$(rstate '.active.waitingFor')" "restart"
assert_eq "old and new number are kept" "$(rstate '.active.data | "\(.old)/\(.new)"')" "1/2"
assert_file "the key of Enrollment CA 02 is a secret" "$(secret_file "${SECRET2}")"
assert_eq "it is the current signing secret" "$(state .enrollmentSecret)" "${SECRET2}"
assert_eq "the current number is 2" "$(state .numbers.enrollment)" "2"
assert_contains "the name is the one of Enrollment CA 02" "$(state .names.enrollment)" "Enrollment CA 02"
assert_eq "the highest number used is 2" "$(state .enrollmentHighest)" "2"
NEW_FP="$(fp "${FILES}/enrollment-ca.pem")"
assert_eq "enrollment-ca.pem is the new certificate" "$([[ "${NEW_FP}" != "${OLD_FP}" ]] && echo new)" "new"
assert_eq "the new certificate is in trust-certs" "$(fp "${FILES}/trust-certs/enrollment-ca-02.pem")" "${NEW_FP}"
assert_eq "the old certificate has its own file" "$(fp "${FILES}/trust-certs/enrollment-ca-01.pem")" "${OLD_FP}"
assert_eq "the manifest points to the files" "$(state '[.trust.entries[] | select(.alias | startswith("enrollment-ca")) | "\(.alias)=\(.file)"] | join(" ")')" "enrollment-ca-01=trust-certs/enrollment-ca-01.pem enrollment-ca-02=trust-certs/enrollment-ca-02.pem"
assert_eq "both are in the server truststore" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-01 enrollment-ca-02 intermediate-ca-01 root-ca-01"
assert_eq "the phones' truststore has neither" "$(aliases "${FILES}/truststore-phone.jks")" "intermediate-ca-01 root-ca-01"
assert_eq "the signing keystore of this node is the new one" "$(signing_fp)" "${NEW_FP}"
assert_eq "the new certificate chains to S and R" "$(openssl verify -CAfile "${FILES}/root-ca.pem" -untrusted "${FILES}/intermediate-ca.pem" "${FILES}/enrollment-ca.pem" > /dev/null 2>&1 && echo yes)" "yes"
assert_contains "the new certificate is a CA with pathlen 0" "$(openssl x509 -in "${FILES}/enrollment-ca.pem" -noout -ext basicConstraints)" "pathlen:0"
assert_file "the new Enrollment CA has a CRL" "${FILES}/crl/enrollment-ca-02.crl"
assert_file "the old one keeps its CRL" "${FILES}/crl/enrollment-ca-01.crl"
assert_eq "the combined CRL file holds both (TAK Server's API reads only the first <crl>)" "$(grep -c 'BEGIN X509 CRL' "${FILES}/crl/00-all.crl")/$(cmp "${FILES}/crl/00-all.crl" <(cat "${FILES}/crl/enrollment-ca-01.crl" "${FILES}/crl/enrollment-ca-02.crl") && echo same)" "2/same"
assert_eq "one restart was requested" "$(ecs_count)" "1"
assert_eq "SigningCARotated" "$(metric_count SigningCARotated)" "1"
assert_eq "no leftovers in tmpfs and files" "$(no_leftovers)" "0/0"
assert_eq "the admin certificate is still the old one's" "$(issuer_ok "${FILES}/admin.pem" "${FILES}/trust-certs/enrollment-ca-01.pem")" "yes"
echo "the admin step waits for a task that started after the switch"
assert_eq "same task, day 12: exit 0" "$(orch 12 0)" "0"
assert_eq "still at admin, waiting for the restart" "$(rstate '.active.steps[.active.index]') $(rstate '.active.waitingFor')" "admin restart"
assert_eq "no second restart" "$(ecs_count)" "1"
assert_eq "no admin certificate registered" "$(grep -c certmod "${STUB_LOG}/java.log")" "0"
assert_eq "a short wait is not a stuck rotation" "$(grep -- '--metric-name RotationWaiting ' "${STUB_LOG}/metrics.log" | tail -1 | sed 's/.*--value \([^ ]*\).*/\1/')" "0"
assert_eq "day 14, still the same task: exit 0" "$(orch 14 0)" "0"
assert_eq "after two days it is a stuck rotation (the deployment failed?)" "$(grep -- '--metric-name RotationWaiting ' "${STUB_LOG}/metrics.log" | tail -1 | sed 's/.*--value \([^ ]*\).*/\1/')" "1"
echo "the new task rotates the admin certificate"
assert_eq "day 15, a task that started at day 12: exit 0" "$(orch 15 12)" "0"
assert_eq "the admin certificate is signed by the new Enrollment CA" "$(issuer_ok "${FILES}/admin.pem" "${FILES}/trust-certs/enrollment-ca-02.pem")" "yes"
assert_eq "TAK Server registered it" "$(grep -c 'certmod -A' "${STUB_LOG}/java.log")" "1"
assert_eq "the previous admin certificate is recorded with its issuer" "$(state '.adminPrevious[0].issuerAlias')" "enrollment-ca-01"
assert_eq "the admin step is done, retire waits for the window" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.waitingFor')" "create,switch,admin window"
assert_eq "the admin step needed no restart" "$(ecs_count)" "1"
assert_eq "day 44, the window (30 days after day 15) is not open: exit 0" "$(orch 44 12)" "0"
assert_eq "retire still waits for the window" "$(rstate '.active.waitingFor')" "window"
echo "retire: window, coverage, approval"
echo 2 > "${STUB_LOG}/coverage.count"
assert_eq "day 46, two users are still on the old Cl: exit 0" "$(orch 46 12)" "0"
assert_eq "retire waits for the coverage" "$(rstate '.active.waitingFor')" "coverage"
assert_contains "the check was asked about the old Enrollment CA" "$(cat "${STUB_LOG}/coverage-args.log")" "--issuer enrollment-ca-01"
assert_eq "the stragglers go to the alert topic" "$(grep -c 'rotation enrollment' "${STUB_LOG}/sns.log")" "1"
assert_eq "a rotation that waits for its coverage is stuck" "$(grep -- '--metric-name RotationWaiting ' "${STUB_LOG}/metrics.log" | tail -1 | sed 's/.*--value \([^ ]*\).*/\1/')" "1"
echo 0 > "${STUB_LOG}/coverage.count"
assert_eq "day 47, everybody has enrolled again: exit 0" "$(orch 47 12)" "0"
assert_eq "retire waits for the approval" "$(rstate '.active.waitingFor')" "approval"
assert_eq "nothing was retired" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-01 enrollment-ca-02 intermediate-ca-01 root-ca-01"
assert_eq "approve: exit 0" "$(NOWDAY=47 rot approve enrollment retire)" "0"
RESTARTS="$(ecs_count)"
assert_eq "day 47, approved: exit 0" "$(orch 47 12)" "0"
assert_eq "the rotation is finished: done" "$(rstate '.active') $(rstate '.history[-1].result') $(rstate '.history[-1].completed | map(.step) | join(",")')" "null done create,switch,admin,retire"
assert_not_contains "retire: a changed combined CRL file is no warning" "$(cat "${WORK}/run.log")" "combined CRL file could not"
assert_eq "the server truststore has only the new Enrollment CA" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-02 intermediate-ca-01 root-ca-01"
assert_eq "the manifest has only the new one" "$(state '[.trust.entries[].alias] | join(",")')" "root-ca-01,intermediate-ca-01,enrollment-ca-02"
assert_no_file "the file of the old certificate is deleted" "${FILES}/trust-certs/enrollment-ca-01.pem"
assert_no_file "the CRL of the old Enrollment CA is deleted" "${FILES}/crl/enrollment-ca-01.crl"
assert_no_file "and its database" "${FILES}/crl/db/enrollment-ca-01"
assert_file "the CRL of the new one stays" "${FILES}/crl/enrollment-ca-02.crl"
assert_eq "the combined CRL file holds only the new one" "$(cmp "${FILES}/crl/00-all.crl" "${FILES}/crl/enrollment-ca-02.crl" && echo same)" "same"
assert_eq "the secret of the stack (generation 1) no longer holds a keystore" "$(openssl pkcs12 -in "$(secret_file "${PKI_ENROLLMENT_CA_SECRET}")" -passin pass:atakatak -nokeys > /dev/null 2>&1 && echo keystore || echo none)" "none"
assert_contains "it says what happened" "$(cat "$(secret_file "${PKI_ENROLLMENT_CA_SECRET}")")" "destroyed"
assert_eq "it was overwritten twice (current and previous version)" "$(grep -c "put-secret-value --secret-id ${PKI_ENROLLMENT_CA_SECRET} " "${STUB_LOG}/aws.log")" "2"
assert_eq "generation 1 is not deleted: it is a stack resource" "$(grep -c 'delete-secret' "${STUB_LOG}/aws.log")" "0"
assert_file "the secret of generation 2 is untouched" "$(secret_file "${SECRET2}")"
assert_eq "the current signing secret is still generation 2" "$(state .enrollmentSecret)" "${SECRET2}"
assert_eq "retire asked for a restart" "$(( $(ecs_count) - RESTARTS ))" "1"
assert_eq "the previous admin certificate of the old CA is marked: its CA is gone" "$(state '.adminPrevious[0].revokedAt')" "retired"
assert_eq "no approval is left" "$(ls -A "${FILES}/.rotation-approvals" 2> /dev/null | wc -l)" "0"
assert_eq "no leftovers in tmpfs and files" "$(no_leftovers)" "0/0"
assert_eq "admin certificate still valid against the new CA only" "$(issuer_ok "${FILES}/admin.pem" "${FILES}/enrollment-ca.pem")" "yes"

echo "a second rotation: the secret of generation 2 is deleted with a recovery window, and a deadline"
assert_eq "day 48, due again (the Enrollment CA 02 is 48 days old): exit 0" "$(orch 48 12)" "0"
assert_eq "the number is 3" "$(rstate '.active.data | "\(.old)/\(.new)"')" "2/3"
assert_file "the secret of generation 3" "$(secret_file "${SECRET3}")"
assert_eq "generation 3 signs" "$(state .enrollmentSecret) $(state .numbers.enrollment)" "${SECRET3} 3"
assert_eq "day 50, the new task: exit 0" "$(orch 50 49)" "0"
assert_eq "retire waits for the window" "$(rstate '.active.waitingFor')" "window"
assert_eq "day 60, the window opens at day 80: exit 0" "$(orch 60 49)" "0"
assert_eq "still the window" "$(rstate '.active.waitingFor')" "window"
echo 3 > "${STUB_LOG}/coverage.count"
assert_eq "day 71, 30 days before the old Cl expires (day 100), three users left: exit 0" "$(orch 71 49)" "0"
assert_eq "the deadline opens window and coverage; the approval stays" "$(rstate '.active.waitingFor')" "approval"
assert_eq "approve" "$(NOWDAY=71 rot approve enrollment retire)" "0"
assert_eq "day 71, approved: exit 0" "$(orch 71 49)" "0"
assert_eq "finished" "$(rstate '.active') $(rstate '.history[-1].result')" "null done"
assert_eq "the secret of generation 2 is deleted with a recovery window of 30 days, not forced" "$(cat "${STUB_LOG}/delete.log")" "id=${SECRET2} window=30 force=0"
assert_no_file "the secret of generation 2 is gone" "$(secret_file "${SECRET2}")"
assert_eq "only generation 3 is trusted" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-03 intermediate-ca-01 root-ca-01"
assert_no_file "CRL of generation 2 deleted" "${FILES}/crl/enrollment-ca-02.crl"
assert_eq "the signing keystore of this node is generation 3" "$(signing_fp)" "$(fp "${FILES}/enrollment-ca.pem")"
assert_eq "retire again (nothing left to do) does not fail" "$(PKI_ROTATION_NOW="$(at 72)" "${TRUST}" retire-signing 2 > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_contains "it says that the secret is scheduled for deletion" "$(cat "${WORK}/run.log")" "is scheduled for deletion already"
assert_eq "the current generation is refused" "$("${TRUST}" retire-signing 3 > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_eq "no leftovers in tmpfs and files" "$(no_leftovers)" "0/0"

echo "a switch that fails, create that runs again, abort"
new_stack abortst
ABORT_OLD_FP="$(fp "${FILES}/enrollment-ca.pem")"
assert_eq "day 11, the truststore cannot be changed: exit 1" "$(orch 11 0 PKI_TRUST_BREAK_INSTALL=1)" "1"
assert_eq "create is done, the switch failed" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.steps[.active.index]') attempts=$(rstate .active.attempts)" "create switch attempts=1"
assert_eq "RotationStepFailed" "$(metric_count RotationStepFailed)" "1"
assert_eq "the signing CA is still the old one" "$(state .numbers.enrollment)" "1"
assert_eq "the server truststore is as before" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-01 intermediate-ca-01 root-ca-01"
assert_eq "no restart was requested" "$(ecs_count)" "0"
CL2_FP="$(fp "${FILES}/trust-certs/enrollment-ca-02.pem")"
jq '.active.index = 0' "${FILES}/rotation-state.json" > "${WORK}/s.json" && cp "${WORK}/s.json" "${FILES}/rotation-state.json"
assert_eq "create runs again after a crash: exit 1 (the switch still fails)" "$(orch 12 0 PKI_TRUST_BREAK_INSTALL=1)" "1"
assert_contains "it continues with the stored secret" "$(cat "${WORK}/run.log")" "the secret ${SECRET2} exists: continuing with it"
assert_eq "it made no other key or certificate" "$(fp "${FILES}/trust-certs/enrollment-ca-02.pem")" "${CL2_FP}"
assert_eq "and no other number" "$(rstate .active.data.new)" "2"
assert_eq "abort: exit 0" "$(NOWDAY=12 rot abort)" "0"
assert_eq "the rotation is aborted" "$(rstate '.active') $(rstate '.history[-1].result')" "null aborted"
assert_eq "the manifest is as before" "$(state '[.trust.entries[].alias] | join(",")')" "root-ca-01,intermediate-ca-01,enrollment-ca-01"
assert_no_file "the file of the new certificate is deleted" "${FILES}/trust-certs/enrollment-ca-02.pem"
assert_no_file "the CRL of the new Enrollment CA is deleted" "${FILES}/crl/enrollment-ca-02.crl"
assert_no_file "the secret of the new Enrollment CA is deleted" "$(secret_file "${SECRET2}")"
assert_eq "with a recovery window" "$(cat "${STUB_LOG}/delete.log")" "id=${SECRET2} window=30 force=0"
assert_eq "the server truststore is as before" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-01 intermediate-ca-01 root-ca-01"
assert_eq "the signing CA is the old one" "$(state .numbers.enrollment) $(signing_fp)" "1 ${ABORT_OLD_FP}"
assert_eq "the number 2 is used up" "$(state .enrollmentHighest)" "2"
assert_eq "no leftovers in tmpfs and files" "$(no_leftovers)" "0/0"
assert_eq "day 13: a new rotation takes the next number: exit 0" "$(orch 13 0)" "0"
assert_eq "the number is 3" "$(rstate '.active.data | "\(.old)/\(.new)"')" "1/3"
assert_eq "the switch is done" "$(state .numbers.enrollment)" "3"
assert_eq "abort after the switch: exit 2, the rotation goes on" "$(NOWDAY=13 rot abort)" "2"
assert_contains "it says why" "$(cat "${WORK}/run.log")" "can only go on"
assert_eq "the rotation is still active" "$(rstate '.active.scenario')" "enrollment"
assert_eq "the new Cl is still the signing CA" "$(state .numbers.enrollment)" "3"
assert_file "its secret is still there" "$(secret_file "${SECRET3}")"

echo "not due"
new_stack notdue
assert_eq "the Intermediate CA has not enough life left: exit 0" "$(orch 600 0 PKI_ENROLLMENT_CA_ROTATION_DAYS=500)" "0"
assert_eq "no rotation" "$(rstate '.active')" "null"
assert_contains "it says why" "$(cat "${WORK}/run.log")" "the Intermediate CA has to be rotated first (#172)"
new_stack two
cl="${WORK}/cl2"
openssl genrsa -out "${cl}.key" 2048 2> /dev/null
openssl req -new -key "${cl}.key" -subj "/O=TAK.NZ/CN=TAK.NZ Try Enrollment CA 02" -out "${cl}.csr"
"${PKI_KMS_CA_SCRIPT}" issue-ca intermediate-ca-01 "${FILES}/intermediate-ca.pem" "${cl}.csr" "${cl}.pem" 90 > /dev/null
assert_eq "a second Enrollment CA in the manifest" "$("${TRUST}" add enrollment-ca-02 "${cl}.pem" server > /dev/null 2>&1; echo $?)" "0"
assert_eq "day 11: exit 0" "$(orch 11 0)" "0"
assert_eq "no rotation while there are two" "$(rstate '.active')" "null"
assert_contains "it says why" "$(cat "${WORK}/run.log")" "lists 2 Enrollment CAs"

[[ "${FAIL}" -eq 0 ]] && echo "passed: ${PASS}, failed: ${FAIL}" || { echo "passed: ${PASS}, failed: ${FAIL}"; exit 1; }
