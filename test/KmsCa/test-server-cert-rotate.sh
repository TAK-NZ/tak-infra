#!/bin/bash
# Tests for docker-container/scripts/server-cert-rotate.sh (#131).
#
# Same set-up as test-pki-bootstrap.sh (test/KmsCa/pki-harness.sh): SoftHSM2 tokens stand in for the KMS
# keys, a stub `aws` stands in for Secrets Manager, CloudWatch and ECS. Each case builds a stack with
# pki-bootstrap.sh and then rotates its server certificate.
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-server-cert-rotate.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
ROTATE="${REPO_ROOT}/docker-container/scripts/server-cert-rotate.sh"
export ECS_Cluster_Name=test-cluster ECS_Service_Name=test-service StackName=TAK-Test SERVER_CERT_ROTATE_RETRY_DELAY=0
export PKI_SERVER_CERT_RENEW_DAYS=60 CLUSTER_LOCK_POLL=0.2

new_stack() { # name server-days [more env assignments...]  -> builds the PKI
  local name="$1" days="$2"
  shift 2
  fresh "${name}"
  env PKI_SERVER_CERT_DAYS="${days}" "$@" "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 || { echo "bootstrap of ${name} failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }
}
rotate() { # check|rotate [env assignments...] -> exit status; output in run.log
  local cmd="$1"
  shift
  env PKI_SERVER_CERT_DAYS=100 "$@" "${ROTATE}" "${cmd}" > "${WORK}/run.log" 2>&1
  echo $?
}
reset_log() { : > "${STUB_LOG}/metrics.log"; : > "${STUB_LOG}/ecs.log"; }
metric_count() { grep -c -- "--metric-name $1 " "${STUB_LOG}/metrics.log"; }
ecs_count() { wc -l < "${STUB_LOG}/ecs.log"; }
sum() { sha256sum "$1" | cut -c1-16; }
sums() { local f; for f in "$@"; do sum "${FILES}/${f}"; done | tr '\n' ' '; }
CERT_SET="takserver.pem takserver.key takserver.p12 takserver.jks"
OTHER_SET="root-ca.pem intermediate-ca.pem enrollment-ca.pem ca.pem admin.p12 admin.pem admin.key truststore-intermediate-ca.jks truststore-phone.jks fed-truststore.jks"
days_left() { echo $(( ( $(date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 )); }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256; }

echo "not applicable"
fresh na
assert_eq "no state file: exit 0" "$(rotate check)" "0"
assert_contains "it says so" "$(cat "${WORK}/run.log")" "not applicable"
( export PKI_KMS_CA_KEYS=""; env "${ROTATE}" check > /dev/null 2>&1 ); assert_eq "no PKI_KMS_CA_KEYS: exit 0" "$?" "0"
"${ROTATE}" bogus > /dev/null 2>&1; assert_eq "an unknown command is refused" "$?" "64"

echo "not due"
new_stack notdue 100
reset_log
before="$(sums ${CERT_SET})"
assert_eq "check with $(days_left "${FILES}/takserver.pem") days left: exit 0" "$(rotate check)" "0"
assert_contains "it reports the days left" "$(cat "${WORK}/run.log")" "99 days left"
assert_eq "nothing changed" "$(sums ${CERT_SET})" "${before}"
assert_eq "no metric" "$(wc -l < "${STUB_LOG}/metrics.log")" "0"
assert_eq "no deployment" "$(ecs_count)" "0"
assert_eq "no .prev copies" "$(ls "${FILES}" | grep -c '\.prev$')" "0"
assert_eq "renewal threshold not smaller than the validity is refused" "$(rotate check PKI_SERVER_CERT_RENEW_DAYS=100)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "must be smaller than PKI_SERVER_CERT_DAYS"

echo "due: the certificate is rotated"
new_stack due 50
reset_log
old_pem_fp="$(fp "${FILES}/takserver.pem")"
old_serial="$(openssl x509 -in "${FILES}/takserver.pem" -noout -serial)"
old_sums="$(sums ${CERT_SET})"
other_before="$(sums ${OTHER_SET})"
old_subject="$(openssl x509 -in "${FILES}/takserver.pem" -noout -subject)"
old_san="$(openssl x509 -in "${FILES}/takserver.pem" -noout -ext subjectAltName)"
cp "${FILES}/takserver.pem" "${WORK}/old-takserver.pem"
assert_eq "the old certificate has $(days_left "${FILES}/takserver.pem") days left" "$(( $(days_left "${FILES}/takserver.pem") <= 60 ))" "1"
assert_eq "check rotates: exit 0" "$(rotate check)" "0"
assert_contains "it logs the rotation" "$(cat "${WORK}/run.log")" "server certificate rotated"
new_fp="$(fp "${FILES}/takserver.pem")"
[[ "${new_fp}" != "${old_pem_fp}" ]] && pass "a new certificate is installed" || fail "a new certificate is installed"
[[ "$(openssl x509 -in "${FILES}/takserver.pem" -noout -serial)" != "${old_serial}" ]] && pass "with a new serial" || fail "with a new serial"
assert_eq "the new certificate has about 100 days" "$(( $(days_left "${FILES}/takserver.pem") >= 98 ))" "1"
assert_eq "same subject" "$(openssl x509 -in "${FILES}/takserver.pem" -noout -subject)" "${old_subject}"
assert_eq "same SAN" "$(openssl x509 -in "${FILES}/takserver.pem" -noout -ext subjectAltName)" "${old_san}"
assert_eq "chains to the Intermediate CA and Root CA" "$(openssl verify -CAfile "${FILES}/root-ca.pem" -untrusted "${FILES}/intermediate-ca.pem" "${FILES}/takserver.pem" 2>&1 | tail -1)" "${FILES}/takserver.pem: OK"
assert_eq "key matches the certificate" "$(openssl x509 -in "${FILES}/takserver.pem" -noout -pubkey | sha256sum)" "$(openssl pkey -in "${FILES}/takserver.key" -pubout | sha256sum)"
assert_eq "takserver.jks holds the new certificate" "$(keytool -exportcert -alias takserver -keystore "${FILES}/takserver.jks" -storepass atakatak -rfc 2> /dev/null | openssl x509 -noout -fingerprint -sha256)" "${new_fp}"
assert_eq "takserver.p12 holds the new certificate" "$(openssl pkcs12 -in "${FILES}/takserver.p12" -passin pass:atakatak -nokeys -clcerts 2> /dev/null | openssl x509 -noout -fingerprint -sha256)" "${new_fp}"
assert_eq "the chain in the keystore is S and R" "$(keytool -list -v -keystore "${FILES}/takserver.jks" -storepass atakatak 2> /dev/null | grep 'Certificate chain length' | awk '{print $4}')" "3"
assert_eq "the .prev copies are the old files" "$(for f in ${CERT_SET}; do sum "${FILES}/${f}.prev"; done | tr '\n' ' ')" "${old_sums}"
assert_eq "the old certificate is in takserver.pem.prev" "$(fp "${FILES}/takserver.pem.prev")" "${old_pem_fp}"
assert_eq "key mode 600" "$(stat -c %a "${FILES}/takserver.key")" "600"
assert_eq "p12 mode 600" "$(stat -c %a "${FILES}/takserver.p12")" "600"
assert_eq "pem mode 644" "$(stat -c %a "${FILES}/takserver.pem")" "644"
assert_eq "jks mode 644" "$(stat -c %a "${FILES}/takserver.jks")" "644"
assert_eq "key.prev mode 600" "$(stat -c %a "${FILES}/takserver.key.prev")" "600"
assert_eq "the other files are untouched" "$(sums ${OTHER_SET})" "${other_before}"
assert_eq "no marker left" "$([[ -e "${FILES}/.takserver-rotation.pending" ]] && echo there || echo gone)" "gone"
assert_eq "no .new files left" "$(ls "${FILES}" | grep -c '\.new$')" "0"
assert_eq "no work directory left in tmpfs" "$(ls "${TMPFS}" | grep -c '^rotate\.')" "0"
assert_eq "the lock is released" "$([[ -e "${FILES}/.locks/server-cert-rotation.lock" ]] && echo held || echo free)" "free"
assert_eq "state file: new notAfter" "$(jq -r .notAfter.server "${FILES}/pki-state.json")" "$(openssl x509 -in "${FILES}/takserver.pem" -noout -enddate | cut -d= -f2)"
assert_eq "state file: rotation time recorded" "$(jq -r '.serverCertRotatedAt | length > 0' "${FILES}/pki-state.json")" "true"
assert_eq "TakServerCertRotated emitted once" "$(metric_count TakServerCertRotated)" "1"
assert_contains "...with the Stack dimension" "$(grep TakServerCertRotated "${STUB_LOG}/metrics.log")" "Stack=TAK-Test"
assert_eq "no failure metric" "$(metric_count TakServerCertRotationFailed)" "0"
assert_eq "one rolling deployment" "$(ecs_count)" "1"
assert_contains "of the right service" "$(cat "${STUB_LOG}/ecs.log")" "--cluster test-cluster --service test-service --force-new-deployment"
# a second check does nothing
reset_log
sum_after="$(sums ${CERT_SET})"
assert_eq "check again: exit 0" "$(rotate check)" "0"
assert_eq "check again: nothing rotated" "$(sums ${CERT_SET})" "${sum_after}"
assert_eq "check again: no metric and no deployment" "$(( $(wc -l < "${STUB_LOG}/metrics.log") + $(ecs_count) ))" "0"
# forced rotation
assert_eq "rotate (forced) although not due: exit 0" "$(rotate rotate)" "0"
[[ "$(sums takserver.pem)" != "$(echo "${sum_after}" | cut -d' ' -f1) " ]] && pass "rotate replaces the certificate" || fail "rotate replaces the certificate"
assert_eq "...and the .prev copy is the one that was there before" "$(fp "${FILES}/takserver.pem.prev")" "${new_fp}"

echo "the new certificate is rejected: nothing changes on the EFS"
new_stack bad 50
reset_log
cat > "${WORK}/kms-corrupt.sh" <<EOF
#!/bin/bash
# the real wrapper, but what it signs for a server certificate is garbage
"${WORK}/kms-ca-wrapper.sh" "\$@" || exit \$?
[[ "\$1" == "sign" ]] && echo "not a certificate" > "\$5"
exit 0
EOF
chmod +x "${WORK}/kms-corrupt.sh"
before="$(sums ${CERT_SET})"
assert_eq "exit 1" "$(rotate check PKI_KMS_CA_SCRIPT="${WORK}/kms-corrupt.sh")" "1"
assert_contains "the log says nothing was installed" "$(cat "${WORK}/run.log")" "nothing was installed"
assert_eq "the files are unchanged" "$(sums ${CERT_SET})" "${before}"
assert_eq "no .prev copies, no marker" "$(ls -a "${FILES}" | grep -c -e '\.prev$' -e 'rotation.pending')" "0"
assert_eq "TakServerCertRotationFailed emitted" "$(metric_count TakServerCertRotationFailed)" "1"
assert_eq "no Rotated metric" "$(metric_count TakServerCertRotated)" "0"
assert_eq "no deployment" "$(ecs_count)" "0"
assert_eq "the lock is released" "$([[ -e "${FILES}/.locks/server-cert-rotation.lock" ]] && echo held || echo free)" "free"
assert_eq "no work directory left in tmpfs" "$(ls "${TMPFS}" | grep -c '^rotate\.')" "0"
reset_log
assert_eq "the next check works again" "$(rotate check)" "0"
assert_eq "and rotates" "$(metric_count TakServerCertRotated)" "1"

echo "installing fails: the previous files are restored"
new_stack rollback 50
reset_log
before="$(sums ${CERT_SET})"
assert_eq "exit 1" "$(rotate check SERVER_CERT_ROTATE_BREAK_INSTALL=1)" "1"
assert_contains "the log says it restored" "$(cat "${WORK}/run.log")" "the previous server certificate is back in place"
assert_eq "the four files are the old ones" "$(sums ${CERT_SET})" "${before}"
assert_eq "no marker left" "$([[ -e "${FILES}/.takserver-rotation.pending" ]] && echo there || echo gone)" "gone"
assert_eq "TakServerCertRotationFailed emitted" "$(metric_count TakServerCertRotationFailed)" "1"
assert_eq "no Rotated metric and no deployment" "$(( $(metric_count TakServerCertRotated) + $(ecs_count) ))" "0"
assert_eq "the old certificate is still valid for TAK Server (jks opens, chain ok)" "$(keytool -list -keystore "${FILES}/takserver.jks" -storepass atakatak 2> /dev/null | grep -c PrivateKeyEntry)" "1"

echo "a swap that was interrupted (task stopped): restored by the next run"
new_stack interrupted 100
reset_log
before="$(sums ${CERT_SET})"
for f in ${CERT_SET}; do cp -p "${FILES}/${f}" "${FILES}/${f}.prev"; done
echo '{"started":"x"}' > "${FILES}/.takserver-rotation.pending"
echo "half written" > "${FILES}/takserver.jks"
echo "half written" > "${FILES}/takserver.p12"
assert_eq "check: exit 0" "$(rotate check)" "0"
assert_contains "it says the swap was interrupted" "$(cat "${WORK}/run.log")" "was interrupted"
assert_eq "the old files are back" "$(sums ${CERT_SET})" "${before}"
assert_eq "the marker is gone" "$([[ -e "${FILES}/.takserver-rotation.pending" ]] && echo there || echo gone)" "gone"
assert_eq "TakServerCertRotationFailed emitted once" "$(metric_count TakServerCertRotationFailed)" "1"
assert_eq "the certificate is not due, so it is not rotated" "$(metric_count TakServerCertRotated)" "0"
echo "the swap was interrupted and there is nothing to restore"
find "${FILES}" -name '*.prev' -delete
echo '{"started":"x"}' > "${FILES}/.takserver-rotation.pending"
reset_log
assert_eq "check: exit 1" "$(rotate check)" "1"
assert_eq "the marker stays" "$([[ -e "${FILES}/.takserver-rotation.pending" ]] && echo there || echo gone)" "there"
assert_contains "the log says nothing is rotated until this is fixed" "$(cat "${WORK}/run.log")" "nothing is rotated until that is fixed"
assert_eq "Failed emitted, nothing rotated" "$(metric_count TakServerCertRotationFailed)/$(metric_count TakServerCertRotated)" "1/0"
assert_eq "the files are still the old ones" "$(sums ${CERT_SET})" "${before}"

echo "the deployment cannot be started"
new_stack nodeploy 50
reset_log
assert_eq "exit 1" "$(rotate check STUB_ECS_FAILS=1)" "1"
assert_eq "the new certificate is installed" "$(( $(days_left "${FILES}/takserver.pem") >= 98 ))" "1"
assert_eq "Rotated and Failed are both emitted" "$(metric_count TakServerCertRotated)/$(metric_count TakServerCertRotationFailed)" "1/1"
assert_contains "the log says TAK Server loads it at the next restart" "$(cat "${WORK}/run.log")" "loads it only at its next restart"
reset_log
new_stack nodeploy2 50
assert_eq "SERVER_CERT_ROTATE_NO_DEPLOY=1 rotates without a deployment" "$(rotate check SERVER_CERT_ROTATE_NO_DEPLOY=1)/$(ecs_count)" "0/0"

echo "the new certificate does not outlive Intermediate CA S"
new_stack shorts 50 PKI_INTERMEDIATE_DAYS=90 PKI_ENROLLMENT_CA_DAYS=60 PKI_ADMIN_CERT_DAYS=50
reset_log
s_left="$(days_left "${FILES}/intermediate-ca.pem")"
assert_eq "check rotates: exit 0" "$(rotate check)" "0"
assert_contains "the log says the validity was capped" "$(cat "${WORK}/run.log")" "the new certificate gets"
assert_eq "the new certificate ends before S (S has ${s_left} days)" "$(( $(days_left "${FILES}/takserver.pem") < s_left && $(days_left "${FILES}/takserver.pem") >= s_left - 3 ))" "1"
new_stack shortest 50 PKI_INTERMEDIATE_DAYS=70 PKI_ENROLLMENT_CA_DAYS=60 PKI_ADMIN_CERT_DAYS=50
reset_log
before="$(sums ${CERT_SET})"
assert_eq "S with less life than the threshold: exit 1" "$(rotate check PKI_SERVER_CERT_RENEW_DAYS=80)" "1"
assert_contains "the log says to rotate the Intermediate CA first" "$(cat "${WORK}/run.log")" "rotate the Intermediate CA first"
assert_eq "nothing changed, Failed emitted" "$(sums ${CERT_SET})/$(metric_count TakServerCertRotationFailed)" "${before}/1"

echo "two nodes check at the same time"
new_stack race 50
reset_log
( rotate check > "${WORK}/rc1" ) &
( env PKI_SERVER_CERT_DAYS=100 "${ROTATE}" check > "${WORK}/run2.log" 2>&1; echo $? > "${WORK}/rc2" ) &
wait
assert_eq "both exit 0" "$(cat "${WORK}/rc1" "${WORK}/rc2" | tr '\n' ' ')" "0 0 "
assert_eq "one rotation" "$(metric_count TakServerCertRotated)" "1"
assert_eq "one deployment" "$(ecs_count)" "1"
assert_eq "no failure" "$(metric_count TakServerCertRotationFailed)" "0"
echo "another node holds the lock"
new_stack locked 50
reset_log
mkdir -p "${FILES}/.locks"
printf 'other:1:1:1 60 othernode\n' > "${FILES}/.locks/server-cert-rotation.lock"
before="$(sums ${CERT_SET})"
assert_eq "exit 75 after the wait" "$(rotate check CLUSTER_LOCK_WAIT=1)" "75"
assert_eq "nothing changed" "$(sums ${CERT_SET})" "${before}"

echo "settings"
new_stack names 50 PKI_SERVER_NAMES="ops.try.tak.nz,tak.try.tak.nz"
assert_eq "a name added to the configuration is in the new certificate" "$(rotate check PKI_SERVER_NAMES=ops.try.tak.nz,tak.try.tak.nz,extra.try.tak.nz)" "0"
assert_contains "...as SAN" "$(openssl x509 -in "${FILES}/takserver.pem" -noout -ext subjectAltName)" "DNS:extra.try.tak.nz"
new_stack aes 50 P12_PROFILE=aes256
assert_eq "the aes256 profile rotates" "$(rotate check P12_PROFILE=aes256)" "0"
assert_contains "takserver.p12 uses AES-256" "$(openssl pkcs12 -in "${FILES}/takserver.p12" -passin pass:atakatak -info -noout 2>&1)" "AES-256-CBC"
new_stack legacy 50
assert_eq "the default profile rotates" "$(rotate check)" "0"
assert_eq "takserver.p12 opens without the legacy provider" "$(openssl pkcs12 -in "${FILES}/takserver.p12" -passin pass:atakatak -nokeys -clcerts 2> /dev/null | grep -c BEGIN)" "1"

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
