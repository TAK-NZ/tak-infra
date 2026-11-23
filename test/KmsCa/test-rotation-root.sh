#!/bin/bash
# Tests for docker-container/scripts/rotation/root.sh, the rotation of the Root CA with a cross-certificate (#169).
#
# Same set-up as test-rotation-enrollment.sh (test/KmsCa/pki-harness.sh): SoftHSM2 tokens stand in for the KMS keys
# (root-ca-01, intermediate-ca-01 and the spare intermediate-ca-02), a stub `aws`, stubs for `java` and `curl` (TAK Server),
# a coverage check that prints a number from a file, a clock that the test moves (PKI_ROTATION_NOW) and the start of the
# task (PKI_ROTATE_TASK_STARTED). The scenario runs inside pki-rotate.sh, as in the container.
#
# The phones are checked with `openssl verify`: a phone's truststore is a set of CA certificates (anchors), a server
# accepts a client certificate when it chains to an anchor of its server truststore (ATAK sends only its leaf).
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-rotation-root.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
ROT="${REPO_ROOT}/docker-container/scripts/pki-rotate.sh"
export StackName=TAK-Test CLUSTER_LOCK_POLL=0.2 ECS_Cluster_Name=test-cluster ECS_Service_Name=test-service PKI_ROTATE_RETRY_DELAY=0
export PKI_KMS_CA_KEYS="${PKI_KMS_CA_KEYS},root-ca-02=33333333-3333-4333-8333-333333333333,intermediate-ca-02=44444444-4444-4444-8444-444444444444"
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
# W = 20 + 10 = 30 days; the Root CA lives 700 days: its own trigger is W + 365 = 395 days left (day 305); the earlier one
# (the Intermediate CA is due and the root has 3 x W + 455 = 545 or fewer) is day 155
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
no_leftovers() { echo "$(ls "${TMPFS}" | grep -c -e '^intermediate\.' -e '^root\.' -e '^enrollment\.' -e '^rotate-admin\.' -e '^rechain\.' -e '^tomb\.' -e '^crl-' -e '^trust')/$(ls -A "${FILES}" | grep -c -e '\.new$' -e '\.restore$')"; }

echo "a stack that is not due"
new_stack main
R_OLD="${WORK}/r-old.pem"; S_PEM="${WORK}/s.pem"
cp "${FILES}/root-ca.pem" "${R_OLD}"; cp "${FILES}/intermediate-ca.pem" "${S_PEM}"
cp "${FILES}/takserver.pem" "${WORK}/l-old.pem"
issue_leaf phone-old
assert_eq "day 5: the Root CA has 695 days left: exit 0" "$(orch 5 0)" "0"
assert_eq "no rotation" "$(rstate '.active')" "null"
echo "due: the Intermediate CA is due and the root has 545 days or fewer left: the root goes first"
assert_eq "day 160 (R has 540 days left, S 340): exit 0" "$(orch 160 0)" "0"
assert_eq "the Root CA rotation starts, not the Intermediate CA rotation" "$(rstate .active.scenario)" "root"
assert_contains "the log says it starts" "$(cat "${WORK}/run.log")" "rotation root started: create -> switch -> admin -> retire"
assert_eq "create and switch are done, the admin step waits for the restart" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.steps[.active.index]') $(rstate '.active.waitingFor')" "create,switch admin restart"
assert_eq "numbers: R 1 to 2, S is 1" "$(rstate '.active.data | "\(.old)/\(.new)/\(.sNum)"')" "1/2/1"
R_NEW="${FILES}/trust-certs/root-ca-02.pem"; C="${FILES}/trust-certs/intermediate-ca-01-cross.pem"
assert_file "R_new is a file" "${R_NEW}"
assert_file "C is a file" "${C}"
assert_eq "R_new is self-signed, has pathlen 3 and another key than R_old" "$(openssl verify -CAfile "${R_NEW}" "${R_NEW}" > /dev/null 2>&1 && echo yes)/$(openssl x509 -in "${R_NEW}" -noout -ext basicConstraints | grep -o 'pathlen:[0-9]')/$([[ "$(pubkey "${R_NEW}")" != "$(pubkey "${R_OLD}")" ]] && echo other)" "yes/pathlen:3/other"
assert_contains "R_new is Root CA 02" "$(openssl x509 -in "${R_NEW}" -noout -subject)" "Root CA 02"
assert_eq "C has the key and the subject of S (the cross-certificate)" "$(pubkey "${C}")/$(openssl x509 -in "${C}" -noout -subject)" "$(pubkey "${S_PEM}")/$(openssl x509 -in "${S_PEM}" -noout -subject)"
assert_eq "C is issued by R_new and has pathlen 2" "$(openssl x509 -in "${C}" -noout -issuer)/$(openssl x509 -in "${C}" -noout -ext basicConstraints | grep -o 'pathlen:[0-9]')" "$(openssl x509 -in "${R_NEW}" -noout -subject | sed 's/^subject=/issuer=/')/pathlen:2"
assert_eq "C chains to R_new (and not to R_old)" "$(openssl verify -CAfile "${R_NEW}" "${C}" > /dev/null 2>&1 && echo yes)/$(openssl verify -CAfile "${R_OLD}" "${C}" > /dev/null 2>&1 && echo yes || echo no)" "yes/no"
assert_eq "C is not capped by S's expiry: it gets the validity setting (500 days) from R_new" "$(( ( $(date -d "$(openssl x509 -in "${C}" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))" "499"
assert_eq "the manifest has R_new and C" "$(state '[.trust.entries[].alias] | sort | join(",")')" "enrollment-ca-01,intermediate-ca-01,intermediate-ca-01-cross,root-ca-01,root-ca-02"
assert_eq "the server truststore: both roots, S, C, Enrollment CA" "$(aliases "${FILES}/truststore-intermediate-ca.jks")" "enrollment-ca-01 intermediate-ca-01 intermediate-ca-01-cross root-ca-01 root-ca-02"
assert_eq "the phone truststore: both roots, S, C" "$(aliases "${FILES}/truststore-phone.jks")" "intermediate-ca-01 intermediate-ca-01-cross root-ca-01 root-ca-02"
assert_eq "the federation truststore: the same" "$(aliases "${FILES}/fed-truststore.jks")" "intermediate-ca-01 intermediate-ca-01-cross root-ca-01 root-ca-02"
assert_eq "the signing keystore has the chain [Cl, C, R_new]" "$(jks_chain "${TMPFS}/intermediate-ca-signing.jks")" "3"
assert_eq "...its second certificate is C (it was S)" "$(openssl pkcs12 -in "${TMPFS}/intermediate-ca-signing.p12" -passin pass:atakatak -nokeys 2> /dev/null | awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | head -1)" "$(fp "${C}")"
assert_eq "...and so has the secret of the Enrollment CA (a new version)" "$(p12_ncerts "$(secret_file "${PKI_ENROLLMENT_CA_SECRET}")")/$(openssl pkcs12 -in "$(secret_file "${PKI_ENROLLMENT_CA_SECRET}")" -passin pass:atakatak -nokeys 2> /dev/null | awk '/BEGIN CERT/{n++} n==3' | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | head -1)" "3/$(fp "${R_NEW}")"
assert_eq "enrollment-chain.pem is [C, R_new]" "$(cmp "${FILES}/enrollment-chain.pem" <(cat "${C}" "${R_NEW}") && echo same)" "same"
assert_eq "ca.pem (the FederateCA secret) is C" "$(fp "${FILES}/ca.pem")" "$(fp "${C}")"
assert_eq "the server certificate and the Root CA file are unchanged" "$(cmp "${FILES}/takserver.pem" "${WORK}/l-old.pem" && echo same)/$(fp "${FILES}/root-ca.pem")/$(state .numbers.root)" "same/$(fp "${R_OLD}")/1"
assert_eq "one restart" "$(ecs_count)" "1"
assert_eq "the fingerprints went to the alert topic" "$(grep -c 'Root CA rotation' "${STUB_LOG}/sns.log")" "1"
assert_contains "...and into the log" "$(cat "${WORK}/run.log")" "$(fp "${R_NEW}")"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"
issue_leaf phone-new
echo "what the phones and the server see after the switch"
PH_OLD="$(store old "${S_PEM}" "${R_OLD}")"; PH_NEW="$(store new "${C}" "${R_NEW}")"
L_PEM="${FILES}/takserver.pem"
assert_eq "a phone on {S, R_old} accepts the server certificate" "$(accepts "${PH_OLD}" "${L_PEM}")" "yes"
assert_eq "a phone on {C, R_new} accepts it too" "$(accepts "${PH_NEW}" "${L_PEM}")" "yes"
assert_eq "a phone on {R_new} alone does not (it needs the Intermediate CA, #170)" "$(accepts "${R_NEW}" "${L_PEM}")" "no"
SERVER="$(bundle_of server)"
assert_eq "the server accepts the client certificates from before and after (the Enrollment CA is its anchor)" "$(accepts "${SERVER}" "${WORK}/leaf-phone-old.pem")$(accepts "${SERVER}" "${WORK}/leaf-phone-new.pem")" "yesyes"
assert_eq "a strict validator: the new client certificate chains through C to R_new" "$(openssl verify -CAfile "${R_NEW}" -untrusted <(cat "${FILES}/enrollment-ca.pem" "${C}") "${WORK}/leaf-phone-new.pem" > /dev/null 2>&1 && echo yes)" "yes"
echo "the admin step waits for a task that started after the switch"
assert_eq "day 161, the old task: exit 0" "$(orch 161 0)" "0"
assert_eq "still waiting for the restart, no second restart" "$(rstate '.active.waitingFor')/$(ecs_count)" "restart/1"
assert_eq "day 162, a task that started at day 161: exit 0" "$(orch 162 161)" "0"
assert_eq "admin.pem: the certificate, Cl, C" "$(ncerts "${FILES}/admin.pem")" "3"
assert_eq "admin.p12: and R_new" "$(p12_ncerts "${FILES}/admin.p12")" "4"
assert_eq "the admin certificate verifies through C to R_new" "$(openssl verify -CAfile "${R_NEW}" -untrusted <(cat "${FILES}/enrollment-ca.pem" "${C}") <(openssl x509 -in "${FILES}/admin.pem") > /dev/null 2>&1 && echo yes)" "yes"
assert_eq "newChainAt is recorded" "$(rstate .active.data.newChainAt)" "$(at 162)"
echo "retire: window, coverage, approval"
assert_eq "day 191: exit 0" "$(orch 191 161)" "0"
assert_eq "the window (30 days after day 162) is not open" "$(rstate '.active.waitingFor')" "window"
echo 2 > "${STUB_LOG}/coverage.count"
assert_eq "day 193, two active phones from before the new root: exit 0" "$(orch 193 161)" "0"
assert_eq "retire waits for the coverage" "$(rstate '.active.waitingFor')" "coverage"
assert_contains "the check was asked for the users from before the switch" "$(cat "${STUB_LOG}/coverage-args.log")" "--issued-before $(at 162)"
echo 0 > "${STUB_LOG}/coverage.count"
assert_eq "everybody has enrolled again: exit 0" "$(orch 193 161)" "0"
assert_eq "retire waits for the approval" "$(rstate '.active.waitingFor')" "approval"
assert_eq "the Root CA is still R_old" "$(state .numbers.root)/$(fp "${FILES}/root-ca.pem")" "1/$(fp "${R_OLD}")"
assert_eq "approve" "$(NOWDAY=193 rot approve root retire)" "0"
RESTARTS="$(ecs_count)"
assert_eq "day 193, approved: exit 0" "$(orch 193 161)" "0"
assert_eq "the rotation is finished" "$(rstate '.active') $(rstate '.history[-1].result') $(rstate '.history[-1].completed | map(.step) | join(",")')" "null done create,switch,admin,retire"
assert_eq "R_new is the Root CA: number, name, file" "$(state .numbers.root) $(state .names.root) $(fp "${FILES}/root-ca.pem")" "2 TAK.NZ Try Root CA 02 $(fp "${R_NEW}")"
assert_eq "C is the Intermediate CA certificate" "$(fp "${FILES}/intermediate-ca.pem")" "$(fp "${C}")"
assert_eq "the manifest: R_new, S (the file of C), Enrollment CA" "$(state '[.trust.entries[] | "\(.alias)=\(.file)"] | sort | join(" ")')" "enrollment-ca-01=enrollment-ca.pem intermediate-ca-01=trust-certs/intermediate-ca-01-cross.pem root-ca-02=trust-certs/root-ca-02.pem"
assert_eq "the server truststore" "$(aliases "${FILES}/truststore-intermediate-ca.jks")" "enrollment-ca-01 intermediate-ca-01 root-ca-02"
assert_eq "the phone and federation truststores: S and R_new" "$(aliases "${FILES}/truststore-phone.jks")/$(aliases "${FILES}/fed-truststore.jks")" "intermediate-ca-01 root-ca-02/intermediate-ca-01 root-ca-02"
assert_eq "the server certificate is new and presents [L, C, R_new]" "$(cmp "${FILES}/takserver.pem" "${WORK}/l-old.pem" > /dev/null && echo same || echo new)/$(jks_chain "${FILES}/takserver.jks")/$(openssl verify -CAfile "${R_NEW}" -untrusted "${C}" "${FILES}/takserver.pem" > /dev/null 2>&1 && echo yes)" "new/3/yes"
assert_eq "...the second certificate of takserver.p12 is C" "$(openssl pkcs12 -in "${FILES}/takserver.p12" -passin pass:atakatak -nokeys 2> /dev/null | awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | head -1)" "$(fp "${C}")"
assert_eq "a phone on {S, R_old} still accepts the server certificate (the S key signs it): retire cuts nobody off" "$(accepts "${PH_OLD}" "${FILES}/takserver.pem")" "yes"
assert_eq "a phone on {C, R_new} too" "$(accepts "${PH_NEW}" "${FILES}/takserver.pem")" "yes"
assert_eq "a browser that trusts only R_new accepts the presented chain" "$(openssl verify -CAfile "${R_NEW}" -untrusted <(openssl pkcs12 -in "${FILES}/takserver.p12" -passin pass:atakatak -nokeys 2> /dev/null) "${FILES}/takserver.pem" > /dev/null 2>&1 && echo yes)" "yes"
assert_eq "the admin certificate carries the new chain" "$(ncerts "${FILES}/admin.pem")/$(p12_ncerts "${FILES}/admin.p12")" "3/4"
SERVER="$(bundle_of server)"
assert_eq "the server still accepts the client certificates from before and after" "$(accepts "${SERVER}" "${WORK}/leaf-phone-old.pem")$(accepts "${SERVER}" "${WORK}/leaf-phone-new.pem")" "yesyes"
assert_eq "one more restart, RootCARotated" "$(( $(ecs_count) - RESTARTS ))/$(grep -c -- '--metric-name RootCARotated ' "${STUB_LOG}/metrics.log")" "1/1"
assert_contains "the log tells the operator what to do with the KMS key" "$(cat "${WORK}/run.log")" "remove generation 1 from pki.kmsCa.rootCaNumbers"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"
echo "generation 1 is not in the configuration any more: everything still works"
assert_eq "day 194 without root-ca-01 in PKI_KMS_CA_KEYS: exit 0" "$(orch 194 161 PKI_KMS_CA_KEYS="root-ca-02=33333333-3333-4333-8333-333333333333,intermediate-ca-01=22222222-2222-4222-8222-222222222222,intermediate-ca-02=44444444-4444-4444-8444-444444444444")" "0"
assert_not_contains "...no error" "$(cat "${WORK}/run.log")" "ERROR"
assert_eq "day 194: nothing starts again (the root has no later generation, S is due)" "$(rstate '.active')" "null"

echo "a switch that fails, create that runs again, abort"
new_stack abortst
ABORT_R_FP="$(fp "${FILES}/root-ca.pem")"; ABORT_CL_FP="$(fp "${FILES}/enrollment-ca.pem")"
assert_eq "day 160, the truststores cannot be changed: exit 1" "$(orch 160 0 PKI_TRUST_BREAK_INSTALL=1)" "1"
assert_eq "create is done, the switch failed" "$(rstate '[.active.completed[].step] | join(",")') $(rstate '.active.steps[.active.index]') attempts=$(rstate .active.attempts)" "create switch attempts=1"
assert_eq "nothing signs with the new root: the chain above Cl is still [S, R]" "$(state .numbers.root)/$(cmp "${FILES}/enrollment-chain.pem" <(cat "${FILES}/intermediate-ca.pem" "${FILES}/root-ca.pem") && echo same)/$(ecs_count)" "1/same/0"
RN_FP="$(fp "${FILES}/trust-certs/root-ca-02.pem")"; CN_FP="$(fp "${FILES}/trust-certs/intermediate-ca-01-cross.pem")"
jq '.active.index = 0' "${FILES}/rotation-state.json" > "${WORK}/s.json" && cp "${WORK}/s.json" "${FILES}/rotation-state.json"
assert_eq "create runs again after a crash: exit 1 (the switch still fails)" "$(orch 161 0 PKI_TRUST_BREAK_INSTALL=1)" "1"
assert_contains "it continues with R_new" "$(cat "${WORK}/run.log")" "the certificate root-ca-02 exists already: continuing with it"
assert_contains "...and with C" "$(cat "${WORK}/run.log")" "the cross-certificate intermediate-ca-01-cross exists already: continuing with it"
assert_eq "it made no other certificate" "$(fp "${FILES}/trust-certs/root-ca-02.pem")/$(fp "${FILES}/trust-certs/intermediate-ca-01-cross.pem")" "${RN_FP}/${CN_FP}"
assert_eq "abort: exit 0" "$(NOWDAY=161 rot abort)" "0"
assert_eq "aborted" "$(rstate '.active') $(rstate '.history[-1].result')" "null aborted"
assert_eq "the manifest is as before" "$(state '[.trust.entries[].alias] | join(",")')" "root-ca-01,intermediate-ca-01,enrollment-ca-01"
assert_no_file "R_new is gone" "${FILES}/trust-certs/root-ca-02.pem"
assert_no_file "C is gone" "${FILES}/trust-certs/intermediate-ca-01-cross.pem"
assert_eq "the truststores are as before" "$(aliases "${FILES}/truststore-intermediate-ca.jks")" "enrollment-ca-01 intermediate-ca-01 root-ca-01"
assert_eq "the root and the signing CA are the old ones" "$(fp "${FILES}/root-ca.pem") $(fp "${FILES}/enrollment-ca.pem")" "${ABORT_R_FP} ${ABORT_CL_FP}"
assert_eq "no restart for the abort (the truststores never changed)" "$(ecs_count)" "0"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"
assert_eq "day 162: a new rotation: exit 0" "$(orch 162 0)" "0"
assert_eq "abort after the switch: exit 2, the rotation goes on" "$(NOWDAY=162 rot abort)" "2"
assert_contains "it says why" "$(cat "${WORK}/run.log")" "this rotation can only go on"
assert_eq "still active at the admin step" "$(rstate '.active.scenario') $(rstate '.active.steps[.active.index]')" "root admin"

echo "a retire that fails halfway runs again"
new_stack retfail
assert_eq "day 160: create and switch" "$(orch 160 0)" "0"
assert_eq "day 162: the admin step" "$(orch 162 161)" "0"
echo 0 > "${STUB_LOG}/coverage.count"
assert_eq "approve" "$(NOWDAY=193 rot approve root retire)" "0"
printf '#!/bin/bash\nexit 1\n' > "${WORK}/fails.sh"; chmod +x "${WORK}/fails.sh"
L_BEFORE="$(fp "${FILES}/takserver.pem")"
assert_eq "day 193, the server certificate cannot be re-issued: exit 1" "$(orch 193 161 PKI_ROTATE_SERVER_SCRIPT="${WORK}/fails.sh")" "1"
assert_eq "retire is retried" "$(rstate '.active.steps[.active.index]') attempts=$(rstate .active.attempts)" "retire attempts=1"
assert_eq "R_new is the Root CA already (the files and the manifest are done)" "$(state .numbers.root)/$(fp "${FILES}/root-ca.pem")" "2/$(fp "${FILES}/trust-certs/root-ca-02.pem")"
assert_eq "the server certificate is still the old one: it validates for both kinds of phone" "$(fp "${FILES}/takserver.pem")" "${L_BEFORE}"
assert_eq "day 194: retire runs again: exit 0" "$(orch 194 161)" "0"
assert_eq "finished, the server certificate is new" "$(rstate '.active') $(rstate '.history[-1].result')/$(accepts "${FILES}/trust-certs/intermediate-ca-01-cross.pem" "${FILES}/takserver.pem")" "null done/yes"
assert_eq "no leftovers" "$(no_leftovers)" "0/0"

echo "start: a rotation now, whatever the trigger"
new_stack startst
assert_eq "usage: no scenario" "$("${ROT}" start > /dev/null 2>&1; echo $?)" "64"
assert_eq "an unknown scenario: exit 1" "$(rot start nonsense)" "1"
assert_contains "...it says which exist" "$(cat "${WORK}/run.log")" "no scenario 'nonsense'"
assert_eq "start root on day 0 (not due): exit 0" "$(env PKI_ROTATION_NOW="$(at 0)" PKI_ROTATE_TASK_STARTED="$(at 0)" "${ROT}" start root > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "the rotation is active and create and switch ran" "$(rstate .active.scenario) $(rstate '[.active.completed[].step] | join(",")')" "root create,switch"
assert_eq "start again while it is active: exit 1" "$(rot start root)" "1"
assert_contains "...it says why" "$(cat "${WORK}/run.log")" "the rotation root is active"
assert_eq "start intermediate while root is active: exit 1" "$(rot start intermediate)" "1"
new_stack nokey
assert_eq "start root without a later generation in the key list: exit 1" "$(env PKI_KMS_CA_KEYS="root-ca-01=11111111-1111-4111-8111-111111111111,intermediate-ca-01=22222222-2222-4222-8222-222222222222" PKI_ROTATION_NOW="$(at 0)" "${ROT}" start root > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_contains "...it says what to do" "$(cat "${WORK}/run.log")" "add the next number to pki.kmsCa.rootCaNumbers"
assert_eq "nothing was started" "$(rstate .active)" "null"
new_stack startint
assert_eq "start intermediate on day 0 (not due): exit 0" "$(env PKI_ROTATION_NOW="$(at 0)" PKI_ROTATE_TASK_STARTED="$(at 0)" "${ROT}" start intermediate > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "...it ran create and bridge" "$(rstate .active.scenario) $(rstate '[.active.completed[].step] | join(",")')" "intermediate create,bridge"
new_stack startenr
assert_eq "start enrollment on day 0 (not due): exit 0" "$(env PKI_ROTATION_NOW="$(at 0)" PKI_ROTATE_TASK_STARTED="$(at 0)" "${ROT}" start enrollment > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "...it ran create and switch" "$(rstate .active.scenario) $(rstate '[.active.completed[].step] | join(",")')" "enrollment create,switch"

echo "precedence between the layers"
new_stack prec
assert_eq "day 160, S is due and the root has 540 days, but the root has no later generation: exit 0" "$(orch 160 0 PKI_KMS_CA_KEYS="root-ca-01=11111111-1111-4111-8111-111111111111,intermediate-ca-01=22222222-2222-4222-8222-222222222222,intermediate-ca-02=44444444-4444-4444-8444-444444444444")" "0"
assert_eq "no rotation: the Intermediate CA waits for the root" "$(rstate .active)" "null"
assert_contains "the log says so" "$(cat "${WORK}/run.log")" "the Root CA has to be rotated first (#169)"
assert_eq "day 150, S is due, the root has 550 days (more than 545): the Intermediate CA rotation starts" "$(orch 150 0)/$(rstate .active.scenario)" "0/intermediate"
new_stack own
assert_eq "day 306: the root has 394 days left (its own trigger, 395): exit 0" "$(orch 306 0)" "0"
assert_eq "the Root CA rotation starts" "$(rstate .active.scenario)" "root"

echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
