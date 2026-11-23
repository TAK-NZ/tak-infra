#!/bin/bash
# Tests for docker-container/scripts/pki-legacy-reset.sh: moving a stack with the PKI of the TAK Server scripts to the
# first-boot PKI. Same set-up as the other PKI tests (test/KmsCa/pki-harness.sh); the new PKI is really built at the end
# by pki-bootstrap.sh (SoftHSM stands in for KMS).
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-pki-legacy-reset.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
RESET="${REPO_ROOT}/docker-container/scripts/pki-legacy-reset.sh"
export StackName=TAK-Test CLUSTER_LOCK_POLL=0.2 ECS_Cluster_Name=test-cluster ECS_Service_Name=test-service PKI_ROTATE_RETRY_DELAY=0
echo "stack-secret" > "${STUB_SECRETS}/stack_TAK-Server_Enrollment-CA"
LEGACY="admin.csr admin.jks admin.key admin.p12 admin.p12.rc2 admin.pem admin-trusted.pem ca.crl ca-do-not-share.key ca-trusted.pem crl_index.txt crl_index.txt.attr intermediate-ca.crl intermediate-ca.csr intermediate-ca.key intermediate-ca.pem intermediate-ca-signing.jks intermediate-ca-signing.p12 intermediate-ca-trusted.pem root-ca-do-not-share.key root-ca.pem root-ca-trusted.pem takserver.csr takserver.jks takserver.key takserver.p12 takserver.pem takserver-trusted.pem truststore-intermediate-ca.jks truststore-intermediate-ca.p12 truststore-root.jks truststore-root.p12 fed-truststore.jks ca.pem"
# a stack with the PKI of the old flow: the files of the list, and what must stay
make_legacy() { # name
  fresh "$1"
  local f
  for f in ${LEGACY}; do echo "old ${f}" > "${FILES}/${f}"; done
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/old.key" -out "${FILES}/ca.pem" -subj "/CN=old-ca" -days 30 2> /dev/null
  mkdir -p "${FILES}/ops.try.tak.nz" "${FILES}/.locks"
  echo "le" > "${FILES}/ops.try.tak.nz/letsencrypt.jks"
  echo "acm" > "${FILES}/aws-acm-root.jks"; echo "oauth" > "${FILES}/oauth-public-key.pem"; echo "by hand" > "${FILES}/alice.p12"
}
reset() { "${RESET}" reset "$@" > "${WORK}/run.log" 2>&1; echo $?; }
legacy_dir() { ls -d "${FILES}"/legacy-pki-* 2> /dev/null | head -1; }
count_legacy_files() { local n=0 f; for f in ${LEGACY}; do [[ -e "${FILES}/${f}" ]] && n=$((n + 1)); done; echo "${n}"; }
echo "refusals"
make_legacy refuse
assert_eq "no PKI_KMS_CA_KEYS: exit 1" "$(PKI_KMS_CA_KEYS= reset)" "1"
assert_contains "...it says why" "$(cat "${WORK}/run.log")" "not set up for the new PKI"
assert_eq "...nothing moved" "$(count_legacy_files)" "$(echo ${LEGACY} | wc -w)"
assert_eq "a setting that bootstrap would refuse (no PKI_ENV_LABEL): exit 1" "$(PKI_ENV_LABEL= reset)" "1"
assert_contains "...it shows the message of the check" "$(cat "${WORK}/run.log")" "PKI_ENV_LABEL is not set"
assert_eq "...nothing moved" "$(count_legacy_files)" "$(echo ${LEGACY} | wc -w)"
mv "${STUB_SECRETS}/stack_TAK-Server_Enrollment-CA" "${WORK}/secret.gone"
assert_eq "the secret of the Enrollment CA cannot be read: exit 1" "$(reset)" "1"
assert_contains "...it says why" "$(cat "${WORK}/run.log")" "cannot be read"
mv "${WORK}/secret.gone" "${STUB_SECRETS}/stack_TAK-Server_Enrollment-CA"
echo '{}' > "${FILES}/pki-state.json"
assert_eq "a stack with pki-state.json: exit 1" "$(reset)" "1"
assert_contains "...it says so" "$(cat "${WORK}/run.log")" "has the new PKI already"
find "${FILES}/pki-state.json" -delete
assert_eq "bad usage: exit 64" "$("${RESET}" bogus > /dev/null 2>&1; echo $?)/$("${RESET}" reset --bogus > /dev/null 2>&1; echo $?)/$("${RESET}" > /dev/null 2>&1; echo $?)" "64/64/64"
assert_eq "restore and purge refuse a name that is not a legacy directory: exit 1" "$("${RESET}" purge ../etc > /dev/null 2>&1; echo $?)/$("${RESET}" restore legacy-pki-nonsense > /dev/null 2>&1; echo $?)" "1/1"
echo "nothing to reset"
fresh empty
assert_eq "no ca.pem: exit 0, nothing to do" "$(reset)" "0"
assert_contains "...it says so" "$(cat "${WORK}/run.log")" "nothing to reset"
echo "dry run"
make_legacy dry
before="$(ls -A "${FILES}" | md5sum)"
assert_eq "dry run: exit 0" "$(reset --dry-run)" "0"
assert_contains "it lists the files" "$(cat "${WORK}/run.log")" "root-ca-do-not-share.key"
assert_eq "...and changes nothing" "$(ls -A "${FILES}" | md5sum)" "${before}"
echo "reset"
make_legacy main
CA_OLD="$(sha256sum "${FILES}/ca.pem" | cut -c1-16)"
assert_eq "reset: exit 0" "$(reset)" "0"
D="$(legacy_dir)"
assert_file "the old files are in legacy-pki-<time>" "${D}/root-ca-do-not-share.key"
assert_eq "...all of them" "$(for f in ${LEGACY}; do [[ -e "${D}/${f}" ]] && echo x; done | wc -l)" "$(echo ${LEGACY} | wc -w)"
assert_eq "...private to root (mode 700)" "$(stat -c %a "${D}")" "700"
assert_eq "...ca.pem is the old one" "$(sha256sum "${D}/ca.pem" | cut -c1-16)" "${CA_OLD}"
assert_eq "none of them is left in the files directory" "$(count_legacy_files)" "0"
assert_eq "Let's Encrypt, ACM root, OAuth key, locks and a package by hand stay" "$([[ -f "${FILES}/ops.try.tak.nz/letsencrypt.jks" && -f "${FILES}/aws-acm-root.jks" && -f "${FILES}/oauth-public-key.pem" && -d "${FILES}/.locks" && -f "${FILES}/alice.p12" ]] && echo yes)" "yes"
assert_no_file "the marker is gone" "${FILES}/.legacy-reset"
assert_contains "it says what to do next" "$(cat "${WORK}/run.log")" "the next start of TAK Server builds the new PKI"
assert_contains "...and the command for the deployment" "$(cat "${WORK}/run.log")" "aws ecs update-service --cluster test-cluster --service test-service --force-new-deployment"
touch "${STUB_LOG}/ecs.log"
assert_eq "no deployment was started without --restart" "$(wc -l < "${STUB_LOG}/ecs.log")" "0"
assert_eq "a second reset: exit 0, nothing to do" "$(reset)" "0"
assert_eq "purge before the new PKI exists: refused (it is the only copy)" "$("${RESET}" purge "${D##*/}" > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_file "...the files are still there" "${D}/root-ca-do-not-share.key"
echo "the next start builds the new PKI"
"${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1
assert_eq "pki-bootstrap.sh: exit 0 (built, not 'old flow')" "$?" "0"
assert_file "the new PKI has its state file" "${FILES}/pki-state.json"
assert_eq "ca.pem is a new certificate" "$([[ "$(sha256sum "${FILES}/ca.pem" | cut -c1-16)" != "${CA_OLD}" ]] && echo new)" "new"
assert_eq "no CA key is on the EFS" "$(ls "${FILES}" | grep -c -e 'do-not-share' -e 'intermediate-ca.key')" "0"
assert_eq "the Root CA is in KMS: root-ca.pem is for a Root CA 01 of the new names" "$(openssl x509 -in "${FILES}/root-ca.pem" -noout -subject)" "subject=O = TAK.NZ, CN = TAK.NZ Try Root CA 01"
assert_eq "admin.p12 opens with OpenSSL 3" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -nokeys 2> /dev/null | grep -c 'BEGIN CERT')" "4"
assert_eq "the file of Let's Encrypt and the hand-made package are untouched" "$(cat "${FILES}/ops.try.tak.nz/letsencrypt.jks")/$(cat "${FILES}/alice.p12")" "le/by hand"
echo "restore and purge after the new PKI"
assert_eq "restore: refused, the new PKI is built" "$("${RESET}" restore "${D##*/}" > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_contains "...it says why" "$(cat "${WORK}/run.log")" "the new PKI was built"
assert_eq "purge with a path: exit 0" "$("${RESET}" purge "${D}" > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_no_file "the old CA keys are gone" "${D}"
echo "restore"
make_legacy back
assert_eq "reset" "$(reset)" "0"
D2="$(legacy_dir)"
assert_eq "restore: exit 0" "$("${RESET}" restore "${D2##*/}" > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "the old PKI is back, the directory is gone" "$(count_legacy_files)/$([[ -d "${D2}" ]] && echo there || echo gone)" "$(echo ${LEGACY} | wc -w)/gone"
assert_eq "ca.pem is the old one again" "$(grep -c 'BEGIN CERT' "${FILES}/ca.pem")" "1"
echo "restore refuses when there is a ca.pem"
assert_eq "reset again, then a ca.pem appears" "$(reset)" "0"
D3="$(legacy_dir)"; echo x > "${FILES}/ca.pem"
assert_eq "restore: refused" "$("${RESET}" restore "${D3##*/}" > /dev/null 2>&1; echo $?)" "1"
echo "an interrupted reset continues"
make_legacy halfway
D4="${FILES}/legacy-pki-20260101T000000Z"; mkdir -p "${D4}"; chmod 700 "${D4}"
echo "${D4##*/}" > "${FILES}/.legacy-reset"
mv "${FILES}/admin.pem" "${FILES}/takserver.jks" "${D4}/"
assert_eq "reset: exit 0" "$(reset)" "0"
assert_contains "it says that it continues" "$(cat "${WORK}/run.log")" "an earlier reset was interrupted: continuing with ${D4}"
assert_eq "all files are in the one directory, no second directory" "$(ls "${D4}" | wc -l)/$(ls -d "${FILES}"/legacy-pki-* | wc -l)/$(count_legacy_files)" "$(echo ${LEGACY} | wc -w)/1/0"
echo "interrupted after ca.pem was moved (no ca.pem, marker present)"
make_legacy lastfile
D5="${FILES}/legacy-pki-20260101T000001Z"; mkdir -p "${D5}"; echo "${D5##*/}" > "${FILES}/.legacy-reset"; mv "${FILES}/ca.pem" "${D5}/"
assert_eq "reset: exit 0 and the rest moves" "$(reset)/$(count_legacy_files)" "0/0"
assert_no_file "the marker is gone" "${FILES}/.legacy-reset"
echo "--restart"
make_legacy restart
: > "${STUB_LOG}/ecs.log"
assert_eq "reset --restart: exit 0" "$(reset --restart)" "0"
assert_eq "one rolling deployment" "$(wc -l < "${STUB_LOG}/ecs.log")" "1"
make_legacy restartfail
assert_eq "a deployment that cannot start: exit 1, the files are moved already" "$(STUB_ECS_FAILS=1 reset --restart)/$(count_legacy_files)" "1/0"
assert_contains "...it names the command" "$(cat "${WORK}/run.log")" "force-new-deployment"
echo "another node holds the lock"
make_legacy locked
mkdir -p "${FILES}/.locks"
printf 'other:1:1:1 60 othernode\n' > "${FILES}/.locks/pki-bootstrap.lock"
assert_eq "exit 75 after the wait" "$(CLUSTER_LOCK_WAIT=1 reset)" "75"
assert_eq "...nothing moved" "$(count_legacy_files)" "$(echo ${LEGACY} | wc -w)"
echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
