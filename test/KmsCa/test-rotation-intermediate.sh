#!/bin/bash
# Tests for docker-container/scripts/rotation/intermediate.sh, the two-phase rotation of the Intermediate CA (#172).
#
# Same set-up as test-rotation-enrollment.sh (test/KmsCa/pki-harness.sh): SoftHSM2 tokens stand in for the KMS keys
# (root-ca-01, intermediate-ca-01 and the spare intermediate-ca-02), a stub `aws`, stubs for `java` and `curl` (TAK Server),
# a coverage check that prints a number from a file, a clock that the test moves (PKI_ROTATION_NOW) and the start of the
# task (PKI_ROTATE_TASK_STARTED). The scenario runs inside pki-rotate.sh, as in the container.
#
# The phones are checked with `openssl verify`: a phone's truststore is a set of CA certificates (anchors), a server
# accepts a client certificate when it chains to an anchor of its server truststore (ATAK sends only its leaf).
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-rotation-intermediate.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
ROT="${REPO_ROOT}/docker-container/scripts/pki-rotate.sh"
export StackName=TAK-Test CLUSTER_LOCK_POLL=0.2 ECS_Cluster_Name=test-cluster ECS_Service_Name=test-service PKI_ROTATE_RETRY_DELAY=0
export PKI_KMS_CA_KEYS="${PKI_KMS_CA_KEYS},intermediate-ca-02=44444444-4444-4444-8444-444444444444"
KEYS_WITH_SPARE="${PKI_KMS_CA_KEYS}"
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
printf '#!/bin/bash\nprintf 200\n' > "${WORK}/bin/curl-stub"
printf '#!/bin/bash\nexit 0\n' > "${WORK}/leaf.sh"
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
# W = 20 + 10 = 30 days; the Intermediate CA lives 500 days: its rotation starts at 2 x 30 + 365 = 425 days left (day 75)
export PKI_ROOT_DAYS=700 PKI_INTERMEDIATE_DAYS=500 PKI_ENROLLMENT_CA_DAYS=100 PKI_SERVER_CERT_DAYS=30 PKI_ADMIN_CERT_DAYS=30
export PKI_CLIENT_CERT_DAYS=20 PKI_ROTATION_BUFFER_DAYS=10 PKI_ENROLLMENT_CA_ROTATION_DAYS=10 PKI_ADMIN_CERT_RENEW_DAYS=10 PKI_SERVER_CERT_RENEW_DAYS=10
T=$(date +%s)
DAY=86400
at() { echo $(( T + $1 * DAY )); }
reset_log() { local f; for f in metrics ecs aws sns java coverage-args delete; do : > "${STUB_LOG}/${f}.log"; done; }
new_stack() { # name
  fresh "$1"
  export StackName="TAK-$1"
  "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 || { echo "bootstrap of $1 failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }
  reset_log
  echo 0 > "${STUB_LOG}/coverage.count"
}
# orch day task-started-day [env...]: exit status; output in run.log
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
ncerts() { grep -c 'BEGIN CERTIFICATE' "$1"; }
p12_ncerts() { openssl pkcs12 -in "$1" -passin pass:atakatak -nokeys 2> /dev/null | grep -c 'BEGIN CERTIFICATE'; }
jks_chain() { keytool -list -v -keystore "$1" -storepass atakatak 2> /dev/null | grep 'Certificate chain length' | awk '{print $4}'; }
secret_file() { echo "${STUB_SECRETS}/$(echo "$1" | tr '/:' '__')"; }
metric_count() { grep -c -- "--metric-name $1 .*Phase=$2" "${STUB_LOG}/metrics.log"; }
ecs_count() { grep -c . "${STUB_LOG}/ecs.log"; }
pem_of() { openssl x509 -in "$1"; }
pubkey() { openssl x509 -in "$1" -noout -pubkey | openssl sha256 | cut -d' ' -f2; }
# a client certificate from the signing key that this node has in tmpfs now
issue_leaf() { # name -> ${WORK}/leaf-<name>.pem
  openssl pkcs12 -in "${TMPFS}/intermediate-ca-signing.p12" -passin pass:atakatak -nodes -nocerts -out "${WORK}/sk.key" 2> /dev/null
  openssl pkcs12 -in "${TMPFS}/intermediate-ca-signing.p12" -passin pass:atakatak -clcerts -nokeys -out "${WORK}/sk.pem" 2> /dev/null
  openssl genrsa -out "${WORK}/lk.key" 2048 2> /dev/null
  openssl req -new -key "${WORK}/lk.key" -subj "/O=TAK.NZ/CN=$1" -out "${WORK}/lk.csr"
  printf '[ client ]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=critical,clientAuth\nauthorityKeyIdentifier=keyid:always\n' > "${WORK}/lk.ext"
  openssl x509 -req -sha256 -days 5 -in "${WORK}/lk.csr" -CA "${WORK}/sk.pem" -CAkey "${WORK}/sk.key" -set_serial 0x$(openssl rand -hex 7) -extfile "${WORK}/lk.ext" -extensions client -out "${WORK}/leaf-$1.pem" 2> /dev/null
  cp "${WORK}/sk.pem" "${WORK}/leaf-$1.signer.pem"
  find "${WORK}/sk.key" "${WORK}/lk.key" -delete
}
# the CA certificates of a truststore set, from the manifest: what a server or a phone trusts
bundle_of() { # set -> file
  local out="${WORK}/bundle-$1.pem" f
  : > "${out}"
  while IFS= read -r f; do cat "${FILES}/${f}" >> "${out}"; done < <(jq -r --arg s "$1" '.trust.entries[] | select(.sets | index($s)) | .file' "${FILES}/pki-state.json")
  echo "${out}"
}
# does a TLS peer with these anchors accept this certificate? (ATAK sends only its leaf: partial chain, dates are not the point)
accepts() { # anchors.pem cert.pem
  openssl verify -no_check_time -partial_chain -CAfile "$1" <(openssl x509 -in "$2") > /dev/null 2>&1 && echo yes || echo no
}
# a phone's store: given as files
store() { local out="${WORK}/store-$1.pem"; shift; cat "$@" > "${out}"; echo "${out}"; }
no_leftovers() { echo "$(ls "${TMPFS}" | grep -c -e '^intermediate\.' -e '^enrollment\.' -e '^rotate-admin\.' -e '^rechain\.' -e '^tomb\.' -e '^crl-' -e '^trust')/$(ls -A "${FILES}" | grep -c -e '\.new$' -e '\.restore$')"; }

echo "a stack that is not due"
new_stack main
S_OLD="${WORK}/s-old.pem"; R_PEM="${WORK}/r.pem"
cp "${FILES}/intermediate-ca.pem" "${S_OLD}"; cp "${FILES}/root-ca.pem" "${R_PEM}"
CL_OLD="${WORK}/cl-old.pem"; cp "${FILES}/enrollment-ca.pem" "${CL_OLD}"
issue_leaf phone-old
L_OLD="${FILES}/takserver.pem"; cp "${L_OLD}" "${WORK}/l-old.pem"
assert_eq "day 5: the Intermediate CA has 495 days left: exit 0" "$(orch 5 0)" "0"
assert_eq "no rotation" "$(rstate '.active')" "null"
assert_eq "the plan shows the trigger" "$(env PKI_ROTATE_BUILTIN_SCENARIOS=1 PKI_ROTATION_NOW="$(at 5)" "${ROT}" plan 2>&1 | grep -c 'Intermediate CA .*orchestrated rotation')" "1"
echo "due: create and bridge"
assert_eq "day 80: 420 days left, due: exit 0" "$(orch 80 0)" "0"
assert_contains "the log says it starts" "$(cat "${WORK}/run.log")" "rotation intermediate started: create -> bridge -> admin -> cut -> retire"
assert_eq "create and bridge are done, the admin step waits for the restart" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.steps[.active.index]') $(rstate '.active.waitingFor')" "create,bridge admin restart"
assert_eq "numbers: S 1 to 2, Enrollment CA 1 to 2" "$(rstate '.active.data | "\(.old)/\(.new)/\(.clOld)/\(.clNew)"')" "1/2/1/2"
A="${FILES}/trust-certs/intermediate-ca-02-bridge.pem"
assert_file "A is a file of its own" "${A}"
assert_contains "A has pathlen 1" "$(openssl x509 -in "${A}" -noout -ext basicConstraints)" "pathlen:1"
assert_contains "A is for Intermediate CA 02" "$(openssl x509 -in "${A}" -noout -subject)" "Intermediate CA 02"
assert_eq "A is issued by S_old" "$(openssl x509 -in "${A}" -noout -issuer)" "$(openssl x509 -in "${S_OLD}" -noout -subject | sed 's/^subject=/issuer=/')"
assert_eq "A chains to R through S_old" "$(openssl verify -CAfile "${R_PEM}" -untrusted "${S_OLD}" "${A}" > /dev/null 2>&1 && echo yes)" "yes"
assert_contains "A is not longer valid than S_old (the days of S_old minus one)" "$(( $(date -d "$(openssl x509 -in "${A}" -noout -enddate | cut -d= -f2)" +%s) <= $(date -d "$(openssl x509 -in "${S_OLD}" -noout -enddate | cut -d= -f2)" +%s) ))" "1"
CL_NEW="${FILES}/trust-certs/enrollment-ca-02.pem"
assert_eq "Enrollment CA 02 is signed by the key of S_new (A is its anchor)" "$(openssl verify -no_check_time -partial_chain -CAfile "${A}" "${CL_NEW}" > /dev/null 2>&1 && echo yes)" "yes"
assert_eq "...and chains to R through A and S_old" "$(openssl verify -CAfile "${R_PEM}" -untrusted <(cat "${A}" "${S_OLD}") "${CL_NEW}" > /dev/null 2>&1 && echo yes)" "yes"
assert_eq "the manifest" "$(state '[.trust.entries[].alias] | sort | join(",")')" "enrollment-ca-01,enrollment-ca-02,intermediate-ca-01,intermediate-ca-02-bridge,root-ca-01"
assert_eq "the server truststore: both Enrollment CAs, S_old, A, R" "$(aliases "${FILES}/truststore-intermediate-ca.jks")" "enrollment-ca-01 enrollment-ca-02 intermediate-ca-01 intermediate-ca-02-bridge root-ca-01"
assert_eq "the phone truststore (data packages): S_old, A, R" "$(aliases "${FILES}/truststore-phone.jks")" "intermediate-ca-01 intermediate-ca-02-bridge root-ca-01"
assert_eq "the federation truststore: the same" "$(aliases "${FILES}/fed-truststore.jks")" "intermediate-ca-01 intermediate-ca-02-bridge root-ca-01"
assert_eq "the signing keystore has the chain [Cl, A, S_old, R]" "$(jks_chain "${TMPFS}/intermediate-ca-signing.jks")" "4"
assert_eq "enrollment-chain.pem is [A, S_old, R]" "$(cmp "${FILES}/enrollment-chain.pem" <(cat "${A}" "${S_OLD}" "${R_PEM}") && echo same)" "same"
assert_eq "enrollment-ca.pem is Enrollment CA 02" "$(fp "${FILES}/enrollment-ca.pem")" "$(fp "${CL_NEW}")"
assert_eq "S_old still signs the server certificate: numbers.intermediate is 1" "$(state .numbers.intermediate) $(fp "${FILES}/intermediate-ca.pem")" "1 $(fp "${S_OLD}")"
assert_eq "the server certificate is unchanged" "$(cmp "${FILES}/takserver.pem" "${WORK}/l-old.pem" && echo same)" "same"
assert_file "Enrollment CA 02 has a CRL" "${FILES}/crl/enrollment-ca-02.crl"
assert_eq "one restart, Phase=bridge, SigningCARotated" "$(ecs_count)/$(metric_count IntermediateCARotationPhase bridge)/$(grep -c -- '--metric-name SigningCARotated ' "${STUB_LOG}/metrics.log")" "1/1/1"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"
issue_leaf phone-bridge
echo "what the phones and the server see at the bridge"
SERVER="$(bundle_of server)"
PH_OLD="$(store old "${S_OLD}" "${R_PEM}")"; PH_BRIDGE="$(store bridge "${A}" "${S_OLD}" "${R_PEM}")"
assert_eq "a phone on {S_old, R} accepts the server certificate" "$(accepts "${PH_OLD}" "${L_OLD}")" "yes"
assert_eq "a phone on {A, S_old, R} accepts it" "$(accepts "${PH_BRIDGE}" "${L_OLD}")" "yes"
assert_eq "the server accepts a client certificate from Enrollment CA 01" "$(accepts "${SERVER}" "${WORK}/leaf-phone-old.pem")" "yes"
assert_eq "...and one from Enrollment CA 02 (the bridge)" "$(accepts "${SERVER}" "${WORK}/leaf-phone-bridge.pem")" "yes"
assert_eq "the certificate of the new enrolment verifies through A and S_old to R (a strict validator)" "$(openssl verify -CAfile "${R_PEM}" -untrusted <(cat "${CL_NEW}" "${A}" "${S_OLD}") "${WORK}/leaf-phone-bridge.pem" > /dev/null 2>&1 && echo yes)" "yes"
echo "the admin step waits for a task that started after the bridge"
assert_eq "day 81, the old task: exit 0" "$(orch 81 0)" "0"
assert_eq "still waiting for the restart, no second restart" "$(rstate '.active.waitingFor')/$(ecs_count)" "restart/1"
assert_eq "day 82, a task that started at day 81: exit 0" "$(orch 82 81)" "0"
assert_eq "the admin certificate is signed by Enrollment CA 02" "$(accepts "${CL_NEW}" "${FILES}/admin.pem")" "yes"
assert_eq "admin.pem: the certificate, Cl, A, S_old" "$(ncerts "${FILES}/admin.pem")" "4"
assert_eq "admin.p12: and R" "$(p12_ncerts "${FILES}/admin.p12")" "5"
assert_eq "bridgeAt is recorded" "$(rstate .active.data.bridgeAt)" "$(at 82)"
assert_eq "the cut waits for the window (30 days after day 82)" "$(rstate '.active.steps[.active.index]') $(rstate '.active.waitingFor')" "cut window"
echo "the cut: window, coverage, approval"
assert_eq "day 111: exit 0" "$(orch 111 81)" "0"
assert_eq "the window is not open" "$(rstate '.active.waitingFor')" "window"
echo 2 > "${STUB_LOG}/coverage.count"
assert_eq "day 113, two active phones from before the bridge: exit 0" "$(orch 113 81)" "0"
assert_eq "the cut waits for the coverage" "$(rstate '.active.waitingFor')" "coverage"
assert_contains "the check was asked for the users from before the bridge" "$(cat "${STUB_LOG}/coverage-args.log")" "--issued-before $(at 82)"
assert_eq "the list goes to the alert topic" "$(grep -c 'rotation intermediate' "${STUB_LOG}/sns.log")" "1"
echo 0 > "${STUB_LOG}/coverage.count"
assert_eq "everybody has enrolled again: exit 0" "$(orch 113 81)" "0"
assert_eq "the cut waits for its approval (cut and retire need one by default)" "$(rstate '.active.waitingFor')" "approval"
assert_eq "nothing was cut" "$(state .numbers.intermediate)/$(cmp "${FILES}/intermediate-ca.pem" "${S_OLD}" && echo same)" "1/same"
assert_eq "approve" "$(NOWDAY=113 rot approve intermediate cut)" "0"
RESTARTS="$(ecs_count)"
assert_eq "day 113, approved: exit 0" "$(orch 113 81)" "0"
B="${FILES}/trust-certs/intermediate-ca-02.pem"
assert_eq "B is issued by the Root CA" "$(openssl x509 -in "${B}" -noout -issuer)" "$(openssl x509 -in "${R_PEM}" -noout -subject | sed 's/^subject=/issuer=/')"
assert_eq "B has the key and the subject of A" "$(pubkey "${B}")/$(openssl x509 -in "${B}" -noout -subject)" "$(pubkey "${A}")/$(openssl x509 -in "${A}" -noout -subject)"
assert_contains "B has pathlen 2" "$(openssl x509 -in "${B}" -noout -ext basicConstraints)" "pathlen:2"
assert_eq "B chains to R" "$(openssl verify -CAfile "${R_PEM}" "${B}" > /dev/null 2>&1 && echo yes)" "yes"
assert_contains "the log says it was a Root CA signature" "$(cat "${WORK}/run.log")" "(a Root CA signature)"
assert_eq "intermediate-ca.pem and ca.pem (FederateCA) are B" "$(fp "${FILES}/intermediate-ca.pem") $(fp "${FILES}/ca.pem")" "$(fp "${B}") $(fp "${B}")"
assert_eq "S_new is the Intermediate CA: number, name" "$(state .numbers.intermediate) $(state .names.intermediate)" "2 TAK.NZ Try Intermediate CA 02"
assert_eq "the certificate of S_old has a file of its own" "$(fp "${FILES}/trust-certs/intermediate-ca-01.pem")" "$(fp "${S_OLD}")"
assert_eq "the manifest has S_old, A and B" "$(state '[.trust.entries[].alias] | sort | join(",")')" "enrollment-ca-01,enrollment-ca-02,intermediate-ca-01,intermediate-ca-02,intermediate-ca-02-bridge,root-ca-01"
assert_eq "the phone truststore: S_old, A, B, R" "$(aliases "${FILES}/truststore-phone.jks")" "intermediate-ca-01 intermediate-ca-02 intermediate-ca-02-bridge root-ca-01"
L_NEW="${FILES}/takserver.pem"
assert_eq "the server certificate is new, signed by S_new" "$(cmp "${L_NEW}" "${WORK}/l-old.pem" > /dev/null && echo same || echo new)/$(accepts "${B}" "${L_NEW}")" "new/yes"
assert_eq "...and not by S_old" "$(accepts "${S_OLD}" "${L_NEW}")" "no"
assert_eq "takserver.jks holds [L, B, R]" "$(jks_chain "${FILES}/takserver.jks")" "3"
assert_eq "the keystore of Enrollment CA 02 in tmpfs has [Cl, B, R]" "$(jks_chain "${TMPFS}/intermediate-ca-signing.jks")" "3"
assert_eq "...and so has its secret (a new version)" "$(p12_ncerts "$(secret_file "${StackName}/TAK-Server/Enrollment-CA-02")")" "3"
assert_eq "enrollment-chain.pem is [B, R]" "$(cmp "${FILES}/enrollment-chain.pem" <(cat "${B}" "${R_PEM}") && echo same)" "same"
assert_eq "the admin certificate is new: Cl and B in admin.pem, 4 certificates in the p12" "$(ncerts "${FILES}/admin.pem")/$(p12_ncerts "${FILES}/admin.p12")" "3/4"
assert_eq "one more restart, Phase=cut" "$(( $(ecs_count) - RESTARTS ))/$(metric_count IntermediateCARotationPhase cut)" "1/1"
assert_eq "cutAt is recorded" "$(rstate .active.data.cutAt)" "$(at 113)"
issue_leaf phone-cut
PH_CUT="$(store cut "${B}" "${R_PEM}")"
echo "what the phones and the server see after the cut"
assert_eq "a phone on {S_old, R} (enrolled before the bridge) no longer accepts the server certificate: it is cut off" "$(accepts "${PH_OLD}" "${L_NEW}")" "no"
assert_eq "a phone on {A, S_old, R} (enrolled during the bridge) does, through A" "$(accepts "${PH_BRIDGE}" "${L_NEW}")" "yes"
assert_eq "a phone on {B, R} (enrolled after the cut) does" "$(accepts "${PH_CUT}" "${L_NEW}")" "yes"
assert_eq "a strict validator on A: L verifies through A and S_old to R" "$(openssl verify -CAfile "${R_PEM}" -untrusted <(cat "${A}" "${S_OLD}") "${L_NEW}" > /dev/null 2>&1 && echo yes)" "yes"
assert_eq "...and on B: through B to R" "$(openssl verify -CAfile "${R_PEM}" -untrusted "${B}" "${L_NEW}" > /dev/null 2>&1 && echo yes)" "yes"
SERVER="$(bundle_of server)"
assert_eq "the server still accepts the three client certificates (Cl_old is trusted until retire)" "$(accepts "${SERVER}" "${WORK}/leaf-phone-old.pem")$(accepts "${SERVER}" "${WORK}/leaf-phone-bridge.pem")$(accepts "${SERVER}" "${WORK}/leaf-phone-cut.pem")" "yesyesyes"
assert_eq "the certificate of the enrolment after the cut verifies through B to R" "$(openssl verify -CAfile "${R_PEM}" -untrusted <(cat "${FILES}/enrollment-ca.pem" "${B}") "${WORK}/leaf-phone-cut.pem" > /dev/null 2>&1 && echo yes)" "yes"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"
echo "retire: window, coverage, approval"
assert_eq "day 142: exit 0" "$(orch 142 114)" "0"
assert_eq "the window (30 days after day 113) is not open" "$(rstate '.active.waitingFor')" "window"
echo 1 > "${STUB_LOG}/coverage.count"
assert_eq "day 144, a phone is still on A: exit 0" "$(orch 144 114)" "0"
assert_contains "the check was asked for the users from before the cut" "$(cat "${STUB_LOG}/coverage-args.log")" "--issued-before $(at 113)"
assert_eq "retire waits for the coverage" "$(rstate '.active.waitingFor')" "coverage"
echo 0 > "${STUB_LOG}/coverage.count"
assert_eq "day 145: exit 0" "$(orch 145 114)" "0"
assert_eq "retire waits for the approval" "$(rstate '.active.waitingFor')" "approval"
assert_eq "approve" "$(NOWDAY=145 rot approve intermediate retire)" "0"
RESTARTS="$(ecs_count)"
assert_eq "day 145, approved: exit 0" "$(orch 145 114)" "0"
assert_eq "the rotation is finished" "$(rstate '.active') $(rstate '.history[-1].result') $(rstate '.history[-1].completed | map(.step) | join(",")')" "null done create,bridge,admin,cut,retire"
assert_eq "the manifest has R, B and Enrollment CA 02" "$(state '[.trust.entries[].alias] | join(",")')" "root-ca-01,enrollment-ca-02,intermediate-ca-02"
assert_eq "the server truststore" "$(aliases "${FILES}/truststore-intermediate-ca.jks")" "enrollment-ca-02 intermediate-ca-02 root-ca-01"
assert_eq "the phone truststore: B and R" "$(aliases "${FILES}/truststore-phone.jks")" "intermediate-ca-02 root-ca-01"
assert_eq "the federation truststore: B and R" "$(aliases "${FILES}/fed-truststore.jks")" "intermediate-ca-02 root-ca-01"
assert_no_file "the file of S_old is deleted" "${FILES}/trust-certs/intermediate-ca-01.pem"
assert_no_file "the file of A is deleted" "${A}"
assert_no_file "the file of Enrollment CA 01 is deleted" "${FILES}/trust-certs/enrollment-ca-01.pem"
assert_no_file "the CRL of Enrollment CA 01 is deleted" "${FILES}/crl/enrollment-ca-01.crl"
assert_eq "the combined CRL file holds only Enrollment CA 02" "$(cmp "${FILES}/crl/00-all.crl" "${FILES}/crl/enrollment-ca-02.crl" && echo same)" "same"
assert_eq "the key of Enrollment CA 01 is destroyed (the secret of the stack holds a text)" "$(openssl pkcs12 -in "$(secret_file "${PKI_ENROLLMENT_CA_SECRET}")" -passin pass:atakatak -nokeys > /dev/null 2>&1 && echo keystore || echo none)" "none"
assert_eq "one more restart, Phase=retire" "$(( $(ecs_count) - RESTARTS ))/$(metric_count IntermediateCARotationPhase retire)" "1/1"
assert_contains "the log tells the operator what to do with the KMS key" "$(cat "${WORK}/run.log")" "remove generation 1 from pki.kmsCa.intermediateCaNumbers"
SERVER="$(bundle_of server)"
assert_eq "the server no longer accepts a client certificate from Enrollment CA 01" "$(accepts "${SERVER}" "${WORK}/leaf-phone-old.pem")" "no"
assert_eq "...it accepts the ones from Enrollment CA 02 (bridge and cut)" "$(accepts "${SERVER}" "${WORK}/leaf-phone-bridge.pem")$(accepts "${SERVER}" "${WORK}/leaf-phone-cut.pem")" "yesyes"
assert_eq "the admin certificate still verifies" "$(accepts "${SERVER}" "${FILES}/admin.pem")" "yes"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"
echo "the next day: no second rotation (the key of generation 3 does not exist)"
assert_eq "day 146: exit 0" "$(orch 146 114)" "0"
assert_eq "no rotation starts" "$(rstate '.active')" "null"
assert_contains "the log asks for the next key generation" "$(cat "${WORK}/run.log")" "PKI_KMS_CA_KEYS has no later generation"
echo "generation 1 is not in the configuration any more: everything still works (the numbers come from the state file)"
assert_eq "day 147 without intermediate-ca-01 in PKI_KMS_CA_KEYS: exit 0" "$(orch 147 114 PKI_KMS_CA_KEYS="root-ca-01=11111111-1111-4111-8111-111111111111,intermediate-ca-02=44444444-4444-4444-8444-444444444444")" "0"
assert_not_contains "...no error" "$(cat "${WORK}/run.log")" "ERROR"
assert_eq "the server certificate rotation runs without generation 1 (forced)" "$(env PKI_KMS_CA_KEYS="root-ca-01=11111111-1111-4111-8111-111111111111,intermediate-ca-02=44444444-4444-4444-8444-444444444444" PKI_ROTATE_NO_DEPLOY=1 "${REPO_ROOT}/docker-container/scripts/server-cert-rotate.sh" rotate > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "...and it is signed by S_new, chain [L, B, R]" "$(accepts "${B}" "${FILES}/takserver.pem")/$(jks_chain "${FILES}/takserver.jks")" "yes/3"

echo "create runs again after a crash, the bridge fails, abort"
new_stack abortst
ABORT_S_OLD_FP="$(fp "${FILES}/intermediate-ca.pem")"; ABORT_CL_OLD_FP="$(fp "${FILES}/enrollment-ca.pem")"
SECRET2="${StackName}/TAK-Server/Enrollment-CA-02"
assert_eq "day 80, the truststores cannot be changed: exit 1" "$(orch 80 0 PKI_TRUST_BREAK_INSTALL=1)" "1"
assert_eq "create is done, the bridge failed" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.steps[.active.index]') attempts=$(rstate .active.attempts)" "create bridge attempts=1"
assert_eq "the signing CA is still Enrollment CA 01, S_old is the Intermediate CA" "$(state .numbers.enrollment)/$(state .numbers.intermediate)" "1/1"
assert_eq "no restart was requested" "$(ecs_count)" "0"
A_FP="$(fp "${FILES}/trust-certs/intermediate-ca-02-bridge.pem")"; CL_FP="$(fp "${FILES}/trust-certs/enrollment-ca-02.pem")"
jq '.active.index = 0' "${FILES}/rotation-state.json" > "${WORK}/s.json" && cp "${WORK}/s.json" "${FILES}/rotation-state.json"
assert_eq "create runs again after a crash: exit 1 (the bridge still fails)" "$(orch 81 0 PKI_TRUST_BREAK_INSTALL=1)" "1"
assert_contains "it continues with the certificate A" "$(cat "${WORK}/run.log")" "the certificate intermediate-ca-02-bridge exists already: continuing with it"
assert_contains "...and with the stored secret" "$(cat "${WORK}/run.log")" "the secret ${SECRET2} exists: continuing with it"
assert_eq "it made no other key or certificate" "$(fp "${FILES}/trust-certs/intermediate-ca-02-bridge.pem")/$(fp "${FILES}/trust-certs/enrollment-ca-02.pem")" "${A_FP}/${CL_FP}"
assert_eq "abort: exit 0" "$(NOWDAY=81 rot abort)" "0"
assert_eq "...the truststores were never changed, so no restart for the abort" "$(ecs_count)" "0"
assert_eq "aborted" "$(rstate '.active') $(rstate '.history[-1].result')" "null aborted"
assert_eq "the manifest is as before" "$(state '[.trust.entries[].alias] | join(",")')" "root-ca-01,intermediate-ca-01,enrollment-ca-01"
assert_no_file "A is gone" "${FILES}/trust-certs/intermediate-ca-02-bridge.pem"
assert_no_file "the new Enrollment CA is gone" "${FILES}/trust-certs/enrollment-ca-02.pem"
assert_no_file "its CRL is gone" "${FILES}/crl/enrollment-ca-02.crl"
assert_no_file "its secret is deleted" "$(secret_file "${SECRET2}")"
assert_eq "with a recovery window" "$(cat "${STUB_LOG}/delete.log")" "id=${SECRET2} window=30 force=0"
assert_eq "the server truststore is as before" "$(aliases "${FILES}/truststore-intermediate-ca.jks")" "enrollment-ca-01 intermediate-ca-01 root-ca-01"
assert_eq "the signing CA and S are the old ones" "$(fp "${FILES}/enrollment-ca.pem") $(fp "${FILES}/intermediate-ca.pem")" "${ABORT_CL_OLD_FP} ${ABORT_S_OLD_FP}"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"
assert_eq "day 82: a new rotation takes the next Enrollment CA number: exit 0" "$(orch 82 0)" "0"
assert_eq "the numbers" "$(rstate '.active.data | "\(.old)/\(.new)/\(.clOld)/\(.clNew)"')" "1/2/1/3"
assert_eq "the bridge is in place" "$(state .numbers.enrollment)" "3"
assert_eq "abort after the bridge: exit 2, the rotation goes on" "$(NOWDAY=82 rot abort)" "2"
assert_contains "it says why" "$(cat "${WORK}/run.log")" "this rotation can only go on"
assert_eq "the rotation is still active at the admin step" "$(rstate '.active.scenario') $(rstate '.active.steps[.active.index]')" "intermediate admin"

echo "a cut that fails halfway runs again"
new_stack cutfail
assert_eq "day 80: create and bridge" "$(orch 80 0)" "0"
assert_eq "day 82: the admin step" "$(orch 82 81)" "0"
echo 0 > "${STUB_LOG}/coverage.count"
assert_eq "approve" "$(NOWDAY=113 rot approve intermediate cut)" "0"
printf '#!/bin/bash\nexit 1\n' > "${WORK}/fails.sh"; chmod +x "${WORK}/fails.sh"
L_BEFORE="$(fp "${FILES}/takserver.pem")"
assert_eq "day 113, the server certificate cannot be re-issued: exit 1" "$(orch 113 81 PKI_ROTATE_SERVER_SCRIPT="${WORK}/fails.sh")" "1"
assert_eq "the cut is retried" "$(rstate '.active.steps[.active.index]') attempts=$(rstate .active.attempts)" "cut attempts=1"
assert_eq "S_new is the Intermediate CA already (B and the manifest are done)" "$(state .numbers.intermediate)/$(fp "${FILES}/intermediate-ca.pem")" "2/$(fp "${FILES}/trust-certs/intermediate-ca-02.pem")"
assert_eq "the server certificate is still the old one: the server still starts" "$(fp "${FILES}/takserver.pem")" "${L_BEFORE}"
assert_eq "the keystore of Enrollment CA 02 already has [Cl, B, R]" "$(jks_chain "${TMPFS}/intermediate-ca-signing.jks")" "3"
B_FP="$(fp "${FILES}/trust-certs/intermediate-ca-02.pem")"
assert_eq "day 114: the cut runs again: exit 0" "$(orch 114 81)" "0"
assert_eq "B is the same certificate (no second Root CA signature)" "$(fp "${FILES}/trust-certs/intermediate-ca-02.pem")" "${B_FP}"
assert_eq "the server certificate is signed by S_new now" "$(accepts "${FILES}/trust-certs/intermediate-ca-02.pem" "${FILES}/takserver.pem")" "yes"
assert_eq "the step is done and retire waits for the window" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.waitingFor')" "create,bridge,admin,cut window"
assert_not_contains "the second run made no second Root CA signature" "$(cat "${WORK}/run.log")" "(a Root CA signature)"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"

echo "not due"
new_stack nospare
assert_eq "no later key generation: exit 0" "$(orch 80 0 PKI_KMS_CA_KEYS="root-ca-01=11111111-1111-4111-8111-111111111111,intermediate-ca-01=22222222-2222-4222-8222-222222222222")" "0"
assert_eq "no rotation" "$(rstate '.active')" "null"
assert_contains "it says what to do" "$(cat "${WORK}/run.log")" "add the next number to pki.kmsCa.intermediateCaNumbers"
new_stack two
cl="${WORK}/cl3"
openssl genrsa -out "${cl}.key" 2048 2> /dev/null
openssl req -new -key "${cl}.key" -subj "/O=TAK.NZ/CN=TAK.NZ Try Enrollment CA 03" -out "${cl}.csr"
"${PKI_KMS_CA_SCRIPT}" issue-ca intermediate-ca-01 "${FILES}/intermediate-ca.pem" "${cl}.csr" "${cl}.pem" 90 > /dev/null
assert_eq "a second Enrollment CA in the manifest" "$("${REPO_ROOT}/docker-container/scripts/pki-trust.sh" add enrollment-ca-03 "${cl}.pem" server > /dev/null 2>&1; echo $?)" "0"
assert_eq "day 80: exit 0" "$(orch 80 0)" "0"
assert_eq "no rotation while there are two" "$(rstate '.active')" "null"
assert_contains "it says why" "$(cat "${WORK}/run.log")" "lists 2 Enrollment CAs"
new_stack late
assert_eq "day 12: an Enrollment CA of age 12 is due, S has 488 days: exit 0" "$(orch 12 0)" "0"
assert_eq "it is the Enrollment CA that starts" "$(rstate '.active.scenario')" "enrollment"
new_stack both
assert_eq "when the Intermediate CA is due, it goes before the Enrollment CA (day 80, a stack that is due for both)" "$(orch 80 0)/$(rstate '.active.scenario')" "0/intermediate"

echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
