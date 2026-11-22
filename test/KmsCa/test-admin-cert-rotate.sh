#!/bin/bash
# Tests for docker-container/scripts/admin-cert-rotate.sh (#132).
#
# Same set-up as test-server-cert-rotate.sh (test/KmsCa/pki-harness.sh): SoftHSM2 tokens stand in for the KMS
# keys, a stub `aws` for Secrets Manager and CloudWatch. Two more stubs stand in for TAK Server: `java`
# (UserManager.jar certmod -A / -s, keeping one registered fingerprint like the user `admin` of TAK Server) and
# `curl` (the certadmin API). Each case builds a stack with pki-bootstrap.sh and then rotates its admin
# certificate.
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-admin-cert-rotate.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
ROTATE="${REPO_ROOT}/docker-container/scripts/admin-cert-rotate.sh"
export StackName=TAK-Test CLUSTER_LOCK_POLL=0.2 PKI_ADMIN_CERT_RENEW_DAYS=60

# --- TAK Server stubs ------------------------------------------------------------------------
cat > "${WORK}/bin/java-stub" <<'EOF'
#!/bin/bash
# java -jar <jar> certmod -A <pem> | certmod -s <pem>. TAK Server finds the admin user by the CN, so there is
# one registered fingerprint: -A replaces it, -s shows it. Each call is logged with the sha256 of the
# admin.pem that is installed at that moment, to show the order.
shift 2
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }
echo "$1 $2 fp=$(fp "$3") installed=$(sha256sum "${PKI_FILES_DIR}/admin.pem" | cut -c1-12) cwd=$(basename "$PWD")" >> "${STUB_LOG}/java.log"
[[ -e "ignite" ]] && echo "ignite already there" >> "${STUB_LOG}/java.log"
mkdir -p ignite && echo x > ignite/work   # what the embedded Ignite node does: it writes into the current directory
case "$1 $2" in
  "certmod -A") [[ "${STUB_JAVA_FAILS:-}" == *A* ]] && exit 1; fp "$3" > "${STUB_LOG}/registered"; exit 0 ;;
  "certmod -s") [[ "${STUB_JAVA_FAILS:-}" == *S* ]] && exit 1
                # the real UserManager.jar writes this to stderr
                printf "\tUsername:      'admin'\n\tRole:          ROLE_ADMIN\n\tFingerprint:   %s\n" "$(cat "${STUB_LOG}/registered" 2> /dev/null)" >&2; exit 0 ;;
esac
exit 2
EOF
cat > "${WORK}/bin/curl-stub" <<'EOF'
#!/bin/bash
# the certadmin API: logs which certificate is used (and the admin.pem installed at that moment)
cert=""
while [[ $# -gt 0 ]]; do [[ "$1" == --cert ]] && cert="$2"; shift; done
echo "fp=$(openssl x509 -in "${cert}" -noout -fingerprint -sha256 | cut -d= -f2) installed=$(sha256sum "${PKI_FILES_DIR}/admin.pem" | cut -c1-12)" >> "${STUB_LOG}/curl.log"
printf '%s' "${STUB_CURL_CODE:-200}"
EOF
chmod +x "${WORK}/bin/java-stub" "${WORK}/bin/curl-stub"
export JAVA_BIN="${WORK}/bin/java-stub" CURL_BIN="${WORK}/bin/curl-stub" TAK_USER_MANAGER_JAR=/nonexistent/UserManager.jar

new_stack() { # name admin-days [more env assignments...] -> builds the PKI
  local name="$1" days="$2"
  shift 2
  fresh "${name}"
  env PKI_ADMIN_CERT_DAYS="${days}" "$@" "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 || { echo "bootstrap of ${name} failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }
}
rotate() { # check|rotate [env assignments...] -> exit status; output in run.log
  local cmd="$1"
  shift
  env PKI_ADMIN_CERT_DAYS=100 "$@" "${ROTATE}" "${cmd}" > "${WORK}/run.log" 2>&1
  echo $?
}
reset_log() { : > "${STUB_LOG}/metrics.log"; : > "${STUB_LOG}/aws.log"; : > "${STUB_LOG}/java.log"; : > "${STUB_LOG}/curl.log"; rm -f "${STUB_LOG}/registered"; }
metric_count() { grep -c -- "--metric-name $1 " "${STUB_LOG}/metrics.log"; }
sum() { sha256sum "$1" | cut -c1-16; }
sums() { local f; for f in "$@"; do sum "${FILES}/${f}"; done | tr '\n' ' '; }
CERT_SET="admin.pem admin.key admin.p12"
OTHER_SET="root-ca.pem intermediate-ca.pem enrollment-ca.pem ca.pem takserver.pem takserver.key takserver.p12 takserver.jks truststore-intermediate-ca.jks truststore-phone.jks fed-truststore.jks"
days_left() { echo $(( ( $(date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 )); }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256; }
fp_plain() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }
leaf_of_pem() { openssl x509 -in "$1"; }
p12_certs() { openssl pkcs12 -in "$1" -passin pass:atakatak -nokeys 2> /dev/null | grep -c "BEGIN CERTIFICATE"; }
no_leftovers() { echo "$(ls "${TMPFS}" | grep -c -e '^rotate-admin\.' -e '^um\.')/$(ls -A "${FILES}" | grep -c -e '\.new$' -e '\.restore$')/$([[ -e "${FILES}/.locks/admin-cert-rotation.lock" ]] && echo held || echo free)"; }

echo "not applicable"
fresh na
assert_eq "no state file: exit 0" "$(rotate check)" "0"
assert_contains "it says so" "$(cat "${WORK}/run.log")" "not applicable"
"${ROTATE}" bogus > /dev/null 2>&1; assert_eq "an unknown command is refused" "$?" "64"

echo "not due"
new_stack notdue 100
reset_log
before="$(sums ${CERT_SET})"
assert_eq "check: exit 0" "$(rotate check)" "0"
assert_contains "it reports the days left" "$(cat "${WORK}/run.log")" "99 days left"
assert_eq "nothing changed" "$(sums ${CERT_SET})" "${before}"
assert_eq "no metric, no TAK Server call, no secret call" "$(wc -l < "${STUB_LOG}/metrics.log")/$(wc -l < "${STUB_LOG}/java.log")/$(wc -l < "${STUB_LOG}/curl.log")/$(grep -c secretsmanager "${STUB_LOG}/aws.log")" "0/0/0/0"
assert_eq "a renewal threshold that is not smaller than the validity is refused" "$(rotate check PKI_ADMIN_CERT_RENEW_DAYS=100)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "must be smaller than PKI_ADMIN_CERT_DAYS"

echo "due: the certificate is rotated"
new_stack due 50
reset_log
old_fp="$(fp "${FILES}/admin.pem")"
old_installed="$(sha256sum "${FILES}/admin.pem" | cut -c1-12)"
old_sums="$(sums ${CERT_SET})"
other_before="$(sums ${OTHER_SET})"
assert_eq "the old certificate has $(days_left "${FILES}/admin.pem") days left" "$(( $(days_left "${FILES}/admin.pem") <= 60 ))" "1"
assert_eq "check rotates: exit 0" "$(rotate check)" "0"
assert_contains "it logs the rotation" "$(cat "${WORK}/run.log")" "admin certificate rotated"
new_fp="$(fp "${FILES}/admin.pem")"
[[ "${new_fp}" != "${old_fp}" ]] && pass "a new certificate is installed" || fail "a new certificate is installed"
assert_eq "subject CN=admin,O=TAK.NZ" "$(openssl x509 -in "${FILES}/admin.pem" -noout -subject -nameopt RFC2253)" "subject=CN=admin,O=TAK.NZ"
assert_eq "about 100 days" "$(( $(days_left "${FILES}/admin.pem") >= 98 ))" "1"
assert_contains "client certificate (clientAuth, not a CA)" "$(openssl x509 -in "${FILES}/admin.pem" -noout -ext extendedKeyUsage,basicConstraints 2>&1)" "CA:FALSE"
assert_eq "chains to Enrollment CA, Intermediate CA and Root CA" "$(openssl verify -CAfile "${FILES}/root-ca.pem" -untrusted <(cat "${FILES}/intermediate-ca.pem" "${FILES}/enrollment-ca.pem") "${FILES}/admin.pem" 2>&1 | tail -1)" "${FILES}/admin.pem: OK"
assert_eq "issued by the Enrollment CA" "$(openssl x509 -in "${FILES}/admin.pem" -noout -issuer -nameopt RFC2253)" "issuer=CN=TAK.NZ Try Enrollment CA 01,O=TAK.NZ"
assert_eq "admin.pem is the certificate, Enrollment CA and Intermediate CA (what the health check sends)" "$(grep -c 'BEGIN CERTIFICATE' "${FILES}/admin.pem")" "3"
assert_eq "admin.key opens with the keystore password" "$(openssl rsa -in "${FILES}/admin.key" -passin pass:atakatak -check -noout 2>&1)" "RSA key ok"
assert_eq "admin.key matches the certificate" "$(openssl pkey -in "${FILES}/admin.key" -passin pass:atakatak -pubout | sha256sum)" "$(openssl x509 -in "${FILES}/admin.pem" -noout -pubkey | sha256sum)"
assert_eq "admin.p12 opens without the legacy provider and holds leaf, Cl, S and R" "$(p12_certs "${FILES}/admin.p12")" "4"
assert_eq "admin.p12 holds the new certificate" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -nokeys -clcerts 2> /dev/null | openssl x509 -noout -fingerprint -sha256)" "${new_fp}"
assert_contains "admin.p12 is 3DES with a SHA-1 MAC (compat3des)" "$(openssl pkcs12 -legacy -in "${FILES}/admin.p12" -passin pass:atakatak -info -noout 2>&1)" "pbeWithSHA1And3-KeyTripleDES-CBC"
assert_eq "the .prev copies are the old files" "$(for f in ${CERT_SET}; do sum "${FILES}/${f}.prev"; done | tr '\n' ' ')" "${old_sums}"
assert_eq "modes: pem 644, key 600, p12 600, key.prev 600" "$(stat -c %a "${FILES}/admin.pem" "${FILES}/admin.key" "${FILES}/admin.p12" "${FILES}/admin.key.prev" | tr '\n' ' ')" "644 600 600 600 "
assert_eq "the other files are untouched" "$(sums ${OTHER_SET})" "${other_before}"
assert_eq "no marker left" "$([[ -e "${FILES}/.admin-rotation.pending" ]] && echo there || echo gone)" "gone"
assert_eq "no work directories, no .new files, lock released" "$(no_leftovers)" "0/0/free"
# registered with TAK Server BEFORE the swap: the installed admin.pem was still the old one at the time
assert_eq "certmod -A was called once for the new certificate" "$(grep -c '^certmod -A fp='"$(fp_plain "${FILES}/admin.pem")" "${STUB_LOG}/java.log")" "1"
assert_contains "...while the old admin.pem was still installed (register before swap)" "$(grep '^certmod -A' "${STUB_LOG}/java.log" | head -1)" "installed=${old_installed}"
assert_eq "TAK Server lists the new certificate as administrator" "$(cat "${STUB_LOG}/registered")" "$(fp_plain "${FILES}/admin.pem")"
assert_eq "UserManager.jar ran in a throw-away directory, not in the work directory or the files directory" "$(grep -c 'cwd=um\.' "${STUB_LOG}/java.log")/$(grep -c . "${STUB_LOG}/java.log")" "2/2"
assert_eq "the API was asked once, with the new certificate, before the swap" "$(grep -c "fp=$(fp_plain "${FILES}/admin.pem") installed=${old_installed}" "${STUB_LOG}/curl.log")/$(wc -l < "${STUB_LOG}/curl.log")" "1/1"
assert_eq "the secret holds the new admin.p12" "$(cmp "${STUB_SECRETS}/TAK-Test_TAK-Server_Admin-Cert" "${FILES}/admin.p12" && echo same)" "same"
assert_contains "...with the file hash as request token (as start-tak.sh)" "$(grep 'Admin-Cert' "${STUB_LOG}/aws.log")" "--client-request-token $(sha256sum "${FILES}/admin.p12" | cut -d' ' -f1)"
assert_eq "state: new notAfter" "$(jq -r .notAfter.admin "${FILES}/pki-state.json")" "$(openssl x509 -in "${FILES}/admin.pem" -noout -enddate | cut -d= -f2)"
assert_eq "state: rotation time and the day the old copies go (7 days)" "$(jq -r '(.adminCertRotatedAt | length > 0) and (((.adminPreviousRemoveAfter | fromdateiso8601) - now) | (. > 6.9*86400 and . < 7.1*86400))' "${FILES}/pki-state.json")" "true"
assert_eq "state: no pending secret" "$(jq -r '.adminSecretPending // false' "${FILES}/pki-state.json")" "false"
assert_eq "AdminCertRotated emitted once, with the Stack dimension" "$(metric_count AdminCertRotated)/$(grep AdminCertRotated "${STUB_LOG}/metrics.log" | grep -c 'Stack=TAK-Test')" "1/1"
assert_eq "no failure metric" "$(metric_count AdminCertRotationFailed)" "0"
assert_eq "no rolling deployment (the files are read on every call)" "$(grep -c 'ecs update-service' "${STUB_LOG}/aws.log")" "0"
echo "the next check, inside the grace period"
reset_log
sum_after="$(sums ${CERT_SET})"
assert_eq "check again: exit 0" "$(rotate check)" "0"
assert_eq "check again: nothing rotated, the .prev copies are still there" "$(sums ${CERT_SET})/$(ls "${FILES}" | grep -c '^admin\..*\.prev$')" "${sum_after}/3"
assert_eq "check again: no metric, no TAK Server call" "$(wc -l < "${STUB_LOG}/metrics.log")/$(wc -l < "${STUB_LOG}/java.log")" "0/0"
echo "after the grace period the copies of the old key are deleted"
jq '.adminPreviousRemoveAfter = "2020-01-01T00:00:00Z"' "${FILES}/pki-state.json" > "${WORK}/state.tmp" && cp "${WORK}/state.tmp" "${FILES}/pki-state.json"
assert_eq "check: exit 0" "$(rotate check)" "0"
assert_eq "the three .prev files are gone" "$(ls "${FILES}" | grep -c '^admin\..*\.prev$')" "0"
assert_eq "the field is gone from the state file" "$(jq -r 'has("adminPreviousRemoveAfter")' "${FILES}/pki-state.json")" "false"
assert_eq "the certificate itself was not rotated" "$(sums ${CERT_SET})" "${sum_after}"
echo "forced rotation"
reset_log
assert_eq "rotate although not due: exit 0" "$(rotate rotate)" "0"
[[ "$(fp "${FILES}/admin.pem")" != "${new_fp}" ]] && pass "rotate replaces the certificate" || fail "rotate replaces the certificate"
assert_eq "...and the .prev copy is the one that was there before" "$(fp "${FILES}/admin.pem.prev")" "${new_fp}"

echo "TAK Server does not accept the new certificate: nothing changes on the EFS"
new_stack apirefuses 50
reset_log
before="$(sums ${CERT_SET})"
old_plain="$(fp_plain "${FILES}/admin.pem")"
assert_eq "the API answers 403: exit 1" "$(rotate check STUB_CURL_CODE=403)" "1"
assert_contains "the log says no file was changed" "$(cat "${WORK}/run.log")" "no file was changed"
assert_eq "the files are unchanged" "$(sums ${CERT_SET})" "${before}"
assert_eq "no .prev copies, no marker" "$(ls -a "${FILES}" | grep -c -e '\.prev$' -e 'rotation.pending')" "0"
assert_eq "the current certificate is registered again" "$(cat "${STUB_LOG}/registered")" "${old_plain}"
assert_eq "AdminCertRotationFailed emitted, AdminCertRotated not" "$(metric_count AdminCertRotationFailed)/$(metric_count AdminCertRotated)" "1/0"
assert_eq "the secret was not touched" "$(grep -c 'Admin-Cert' "${STUB_LOG}/aws.log")" "0"
assert_eq "no work directories, no .new files, lock released" "$(no_leftovers)" "0/0/free"
reset_log
assert_eq "the next check rotates" "$(rotate check)/$(metric_count AdminCertRotated)" "0/1"
echo "registering fails"
new_stack regfails 50
reset_log
before="$(sums ${CERT_SET})"
assert_eq "certmod -A fails: exit 1" "$(rotate check STUB_JAVA_FAILS=A)" "1"
assert_eq "the files are unchanged" "$(sums ${CERT_SET})" "${before}"
assert_eq "Failed emitted" "$(metric_count AdminCertRotationFailed)" "1"
echo "TAK Server does not list the certificate as administrator"
reset_log
assert_eq "certmod -s fails: exit 1" "$(rotate check STUB_JAVA_FAILS=S)" "1"
assert_eq "the files are unchanged" "$(sums ${CERT_SET})" "${before}"
echo "the Enrollment CA keystore is missing (the task has not restored it)"
reset_log
mv "${TMPFS}/intermediate-ca-signing.p12" "${WORK}/signer.p12"
assert_eq "exit 1" "$(rotate check)" "1"
assert_contains "the log says why" "$(cat "${WORK}/run.log")" "is not there"
assert_eq "the files are unchanged, TAK Server was not asked" "$(sums ${CERT_SET})/$(wc -l < "${STUB_LOG}/java.log" | tr -d ' ')" "${before}/1"
mv "${WORK}/signer.p12" "${TMPFS}/intermediate-ca-signing.p12"

echo "installing fails: the previous files are restored and the old certificate is registered again"
new_stack rollback 50
reset_log
before="$(sums ${CERT_SET})"
old_plain="$(fp_plain "${FILES}/admin.pem")"
assert_eq "exit 1" "$(rotate check ADMIN_CERT_ROTATE_BREAK_INSTALL=1)" "1"
assert_contains "the log says it restored" "$(cat "${WORK}/run.log")" "the previous admin certificate is back in place"
assert_eq "the three files are the old ones" "$(sums ${CERT_SET})" "${before}"
assert_eq "no marker left" "$([[ -e "${FILES}/.admin-rotation.pending" ]] && echo there || echo gone)" "gone"
assert_eq "the old certificate is registered again" "$(cat "${STUB_LOG}/registered")" "${old_plain}"
assert_eq "Failed emitted, Rotated not, the secret not touched" "$(metric_count AdminCertRotationFailed)/$(metric_count AdminCertRotated)/$(grep -c 'Admin-Cert' "${STUB_LOG}/aws.log")" "1/0/0"

echo "a swap that was interrupted (task stopped): restored by the next run"
new_stack interrupted 100
reset_log
before="$(sums ${CERT_SET})"
old_plain="$(fp_plain "${FILES}/admin.pem")"
for f in ${CERT_SET}; do cp -p "${FILES}/${f}" "${FILES}/${f}.prev"; done
echo '{"started":"x"}' > "${FILES}/.admin-rotation.pending"
echo "half written" > "${FILES}/admin.p12"
echo "half written" > "${FILES}/admin.key"
assert_eq "check: exit 0" "$(rotate check)" "0"
assert_contains "it says the swap was interrupted" "$(cat "${WORK}/run.log")" "was interrupted"
assert_eq "the old files are back" "$(sums ${CERT_SET})" "${before}"
assert_eq "the marker is gone" "$([[ -e "${FILES}/.admin-rotation.pending" ]] && echo there || echo gone)" "gone"
assert_eq "the old certificate is registered again" "$(cat "${STUB_LOG}/registered")" "${old_plain}"
assert_eq "Failed emitted once, nothing rotated (not due)" "$(metric_count AdminCertRotationFailed)/$(metric_count AdminCertRotated)" "1/0"
echo "interrupted, and there is nothing to restore"
find "${FILES}" -name '*.prev' -delete
echo '{"started":"x"}' > "${FILES}/.admin-rotation.pending"
reset_log
assert_eq "check: exit 1" "$(rotate check)" "1"
assert_eq "the marker stays" "$([[ -e "${FILES}/.admin-rotation.pending" ]] && echo there || echo gone)" "there"
assert_contains "the log says nothing is rotated until this is fixed" "$(cat "${WORK}/run.log")" "nothing is rotated until that is fixed"
assert_eq "the files are still the old ones" "$(sums ${CERT_SET})" "${before}"

echo "the secret cannot be updated"
new_stack nosecret 50
reset_log
assert_eq "exit 1" "$(rotate check STUB_SECRET_WRITE_FAILS=1)" "1"
assert_eq "the new certificate is installed" "$(( $(days_left "${FILES}/admin.pem") >= 98 ))" "1"
assert_eq "Rotated and Failed are both emitted" "$(metric_count AdminCertRotated)/$(metric_count AdminCertRotationFailed)" "1/1"
assert_eq "the state file remembers it" "$(jq -r .adminSecretPending "${FILES}/pki-state.json")" "true"
assert_contains "the log says the secret still holds the old file" "$(cat "${WORK}/run.log")" "the secret still holds the old admin.p12"
reset_log
new_pem="$(sums admin.pem)"
assert_eq "the next check tries the secret again: exit 0" "$(rotate check)" "0"
assert_eq "the secret now holds the new file" "$(cmp "${STUB_SECRETS}/TAK-Test_TAK-Server_Admin-Cert" "${FILES}/admin.p12" && echo same)" "same"
assert_eq "the pending flag is cleared, no second rotation, no failure" "$(jq -r '.adminSecretPending // false' "${FILES}/pki-state.json")/$(sums admin.pem)/$(metric_count AdminCertRotationFailed)/$(metric_count AdminCertRotated)" "false/${new_pem}/0/0"

echo "the new certificate does not outlive the Enrollment CA"
new_stack shortcl 50 PKI_ENROLLMENT_CA_DAYS=90 PKI_SERVER_CERT_DAYS=50
reset_log
cl_left="$(days_left "${FILES}/enrollment-ca.pem")"
assert_eq "check rotates: exit 0" "$(rotate check)" "0"
assert_contains "the log says the validity was capped" "$(cat "${WORK}/run.log")" "the new certificate gets"
assert_eq "the new certificate ends before the Enrollment CA (cl has ${cl_left} days)" "$(( $(days_left "${FILES}/admin.pem") < cl_left ))" "1"
assert_eq "...and has about the days the Enrollment CA has left" "$(( $(days_left "${FILES}/admin.pem") >= cl_left - 3 ))" "1"
new_stack tooshort 50 PKI_ENROLLMENT_CA_DAYS=70 PKI_SERVER_CERT_DAYS=50
reset_log
before="$(sums ${CERT_SET})"
assert_eq "an Enrollment CA with less life than the threshold: exit 1" "$(rotate check PKI_ADMIN_CERT_RENEW_DAYS=80)" "1"
assert_contains "the log says to rotate the Enrollment CA first" "$(cat "${WORK}/run.log")" "rotate the Enrollment CA first"
assert_eq "nothing changed, Failed emitted" "$(sums ${CERT_SET})/$(metric_count AdminCertRotationFailed)" "${before}/1"

echo "two nodes check at the same time"
new_stack race 50
reset_log
( rotate check > "${WORK}/rc1" ) &
( env PKI_ADMIN_CERT_DAYS=100 "${ROTATE}" check > "${WORK}/run2.log" 2>&1; echo $? > "${WORK}/rc2" ) &
wait
assert_eq "both exit 0" "$(cat "${WORK}/rc1" "${WORK}/rc2" | tr '\n' ' ')" "0 0 "
assert_eq "one rotation, one secret update, no failure" "$(metric_count AdminCertRotated)/$(grep -c 'Admin-Cert' "${STUB_LOG}/aws.log")/$(metric_count AdminCertRotationFailed)" "1/1/0"
echo "another node holds the lock"
new_stack locked 50
reset_log
mkdir -p "${FILES}/.locks"
printf 'other:1:1:1 60 othernode\n' > "${FILES}/.locks/admin-cert-rotation.lock"
before="$(sums ${CERT_SET})"
assert_eq "exit 75 after the wait" "$(rotate check CLUSTER_LOCK_WAIT=1)" "75"
assert_eq "nothing changed" "$(sums ${CERT_SET})" "${before}"

echo "settings"
new_stack aes 50 P12_PROFILE=aes256
assert_eq "the aes256 profile rotates" "$(rotate check P12_PROFILE=aes256)" "0"
assert_contains "admin.p12 uses AES-256" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -info -noout 2>&1)" "AES-256-CBC"

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
