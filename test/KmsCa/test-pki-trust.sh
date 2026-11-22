#!/bin/bash
# Tests for docker-container/scripts/pki-trust-lib.sh and pki-trust.sh (#171, slice B): the manifest of what
# TAK Server trusts, the truststores built from it, and the signing keystore generations.
#
# Same set-up as the other PKI tests (test/KmsCa/pki-harness.sh): SoftHSM2 tokens for the KMS keys (a second
# Enrollment CA is signed by Intermediate CA S through kms-ca.sh), a stub `aws` for Secrets Manager.
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-pki-trust.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
TRUST="${REPO_ROOT}/docker-container/scripts/pki-trust.sh"
export StackName=TAK-Test CLUSTER_LOCK_POLL=0.2

new_stack() { fresh "$1"; "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 || { echo "bootstrap failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }; }
trust() { "${TRUST}" "$@" > "${WORK}/run.log" 2>&1; echo $?; }
aliases() { keytool -list -keystore "$1" -storepass atakatak 2> /dev/null | grep -E 'trustedCertEntry|PrivateKeyEntry' | cut -d, -f1 | sort | tr '\n' ' ' | sed 's/ $//'; }
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }
jks_fp() { keytool -list -keystore "$1" -storepass atakatak 2> /dev/null | awk -v a="$2" '/trustedCertEntry|PrivateKeyEntry/ {split($0, x, ","); cur = x[1]} /SHA-256\)/ {if (cur == a) print $NF}'; }
state() { jq -r "$1" "${FILES}/pki-state.json"; }
SERVER_JKS=truststore-intermediate-ca.jks; PHONE_JKS=truststore-phone.jks; FED_JKS=fed-truststore.jks
FILES_SET="truststore-intermediate-ca.jks truststore-intermediate-ca.p12 truststore-phone.jks truststore-phone.p12 fed-truststore.jks"
sums() { local f; for f in "$@"; do sha256sum "${FILES}/${f}" | cut -c1-16; done | tr '\n' ' '; }
# a new Enrollment CA, signed by Intermediate CA S in KMS (as #135 will do)
make_cl() { # name number -> $WORK/<name>.pem and .key
  openssl genrsa -out "${WORK}/$1.key" 2048 2> /dev/null
  openssl req -new -key "${WORK}/$1.key" -subj "/O=TAK.NZ/CN=TAK.NZ Try Enrollment CA $2" -out "${WORK}/$1.csr"
  "${PKI_KMS_CA_SCRIPT}" issue-ca intermediate-ca-01 "${FILES}/intermediate-ca.pem" "${WORK}/$1.csr" "${WORK}/$1.pem" 1000 > /dev/null || { echo "could not sign $1"; exit 1; }
}

echo "setup"
new_stack main
assert_eq "no state file elsewhere: not applicable" "$(fresh na; trust show)" "0"
FILES="${WORK}/main/files"; TMPFS="${WORK}/main/tmpfs"; export PKI_FILES_DIR="${FILES}" PKI_TMPFS_DIR="${TMPFS}"

echo "the manifest of a new PKI"
assert_eq "bootstrap wrote it: three entries" "$(state '.trust.entries | map(.alias) | join(",")')" "root-ca-01,intermediate-ca-01,enrollment-ca-01"
assert_eq "sets: R and S for everyone, Enrollment CA for the server only" "$(state '.trust.entries | map(.sets | join("+")) | join(" ")')" "server+phone+fed server+phone+fed server"
assert_eq "server truststore: R, S and the Enrollment CA" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-01 intermediate-ca-01 root-ca-01"
assert_eq "phone truststore: R and S" "$(aliases "${FILES}/${PHONE_JKS}")" "intermediate-ca-01 root-ca-01"
assert_eq "federation truststore: R and S" "$(aliases "${FILES}/${FED_JKS}")" "intermediate-ca-01 root-ca-01"
assert_eq "show: exit 0, lists the entries and the files" "$(trust show)/$(grep -c 'enrollment-ca-01' "${WORK}/run.log")" "0/2"
echo "apply on an unchanged manifest does nothing"
before="$(sums ${FILES_SET})"
assert_eq "exit 0" "$(trust apply)" "0"
assert_contains "it says so" "$(cat "${WORK}/run.log")" "nothing to do"
assert_eq "no file changed, no .prev, no marker" "$(sums ${FILES_SET})/$(ls -a "${FILES}" | grep -c -e '\.prev$' -e 'trust-apply')" "${before}/0"
echo "a PKI from before the manifest existed gets the default one"
jq 'del(.trust)' "${FILES}/pki-state.json" > "${WORK}/s.json" && cp "${WORK}/s.json" "${FILES}/pki-state.json"
assert_eq "apply: exit 0 (the default manifest equals what is installed)" "$(trust apply)" "0"
assert_eq "the manifest is back" "$(state '.trust.entries | length')" "3"

echo "a second Enrollment CA"
make_cl cl2 02
assert_eq "add enrollment-ca-02 for the server: exit 0" "$(trust add enrollment-ca-02 "${WORK}/cl2.pem" server)" "0"
assert_eq "the manifest has it, the certificate is kept on the EFS" "$(state '.trust.entries | length')/$(state '.trust.entries[3].file')/$(cmp "${WORK}/cl2.pem" "${FILES}/trust-certs/enrollment-ca-02.pem" && echo same)" "4/trust-certs/enrollment-ca-02.pem/same"
assert_eq "adding does not change the truststores yet" "$(sums ${FILES_SET})" "${before}"
assert_eq "apply: exit 10 (changed: TAK Server must restart)" "$(trust apply)" "10"
assert_eq "server truststore: R, S, both Enrollment CAs" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-01 enrollment-ca-02 intermediate-ca-01 root-ca-01"
assert_eq "the new entry is the certificate that was added" "$(jks_fp "${FILES}/${SERVER_JKS}" enrollment-ca-02)" "$(fp "${WORK}/cl2.pem")"
assert_eq "phone and federation truststores are unchanged" "$(aliases "${FILES}/${PHONE_JKS}")/$(aliases "${FILES}/${FED_JKS}")" "intermediate-ca-01 root-ca-01/intermediate-ca-01 root-ca-01"
assert_eq "the server p12 holds the same four entries" "$(keytool -list -storetype PKCS12 -keystore "${FILES}/truststore-intermediate-ca.p12" -storepass atakatak 2> /dev/null | grep -c trustedCertEntry)" "4"
assert_eq "the phone p12 holds two" "$(keytool -list -storetype PKCS12 -keystore "${FILES}/truststore-phone.p12" -storepass atakatak 2> /dev/null | grep -c trustedCertEntry)" "2"
assert_eq "the .prev copies are the previous files" "$(for f in ${FILES_SET}; do sha256sum "${FILES}/${f}.prev" | cut -c1-16; done | tr '\n' ' ')" "${before}"
assert_eq "no marker, no .new files" "$(ls -a "${FILES}" | grep -c -e 'trust-apply' -e '\.new$' -e '\.restore$')" "0"
assert_eq "modes 644" "$(stat -c %a "${FILES}/${SERVER_JKS}" "${FILES}/truststore-intermediate-ca.p12" | tr '\n' ' ')" "644 644 "
assert_eq "no work directory left in tmpfs" "$(ls "${TMPFS}" | grep -c '^trust\.')" "0"
assert_eq "the lock is released" "$([[ -e "${FILES}/.locks/pki-rotation.lock" ]] && echo held || echo free)" "free"
after_add="$(sums ${FILES_SET})"
assert_eq "apply again: exit 0, nothing to do" "$(trust apply)" "0"
assert_eq "...and the files are unchanged" "$(sums ${FILES_SET})" "${after_add}"
echo "adding something that does not belong is refused"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/foreign.key" -out "${WORK}/foreign.pem" -subj "/CN=Foreign CA" -days 30 -addext "basicConstraints=critical,CA:TRUE" 2> /dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/other-root.key" -out "${WORK}/other-root.pem" -subj "/CN=Other Root" -days 30 -addext "basicConstraints=critical,CA:TRUE" 2> /dev/null
openssl req -newkey rsa:2048 -nodes -keyout "${WORK}/other-sub.key" -out "${WORK}/other-sub.csr" -subj "/CN=Other Sub" 2> /dev/null
openssl x509 -req -in "${WORK}/other-sub.csr" -CA "${WORK}/other-root.pem" -CAkey "${WORK}/other-root.key" -CAcreateserial -out "${WORK}/other-sub.pem" -days 30 -extfile <(echo "basicConstraints=critical,CA:TRUE") 2> /dev/null
assert_eq "a server certificate (not a CA): refused" "$(trust add leaf "${FILES}/takserver.pem" server)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "is not a CA certificate"
assert_eq "a CA of another hierarchy: refused" "$(trust add other-sub "${WORK}/other-sub.pem" server)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "does not chain to the Root CA"
assert_eq "a file that is no certificate: refused" "$(trust add junk "${WORK}/bootstrap.log" server)" "1"
assert_eq "an unknown set: refused" "$(trust add enrollment-ca-09 "${WORK}/cl2.pem" servers)" "1"
assert_eq "an invalid alias: refused" "$(trust add 'Bad Alias' "${WORK}/cl2.pem" server)" "1"
assert_eq "wrong number of arguments: 64" "$(trust add only-one)" "64"
assert_eq "the manifest is unchanged by all of this" "$(state '.trust.entries | length')" "4"
echo "removing an entry"
assert_eq "remove enrollment-ca-01: exit 0" "$(trust remove enrollment-ca-01)" "0"
assert_eq "remove something that is not there: exit 1" "$(trust remove enrollment-ca-77)" "1"
assert_eq "apply: exit 10" "$(trust apply)" "10"
assert_eq "server truststore: R, S, Enrollment CA 02" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-02 intermediate-ca-01 root-ca-01"
after_remove="$(sums ${FILES_SET})"

echo "installing fails: the previous files are restored"
make_cl cl3 03
trust add enrollment-ca-03 "${WORK}/cl3.pem" server > /dev/null
assert_eq "apply with a damaged install: exit 1" "$(PKI_TRUST_BREAK_INSTALL=1 "${TRUST}" apply > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_contains "the log says it restored" "$(cat "${WORK}/run.log")" "the previous files"
assert_eq "the five files are the ones from before" "$(sums ${FILES_SET})" "${after_remove}"
assert_eq "no marker left" "$([[ -e "${FILES}/.trust-apply.pending" ]] && echo there || echo gone)" "gone"
assert_eq "the next apply, without the damage, works" "$(trust apply)" "10"
assert_eq "server truststore now holds Enrollment CA 03 too" "$(aliases "${FILES}/${SERVER_JKS}")" "enrollment-ca-02 enrollment-ca-03 intermediate-ca-01 root-ca-01"
good="$(sums ${FILES_SET})"

echo "a swap that was interrupted (task stopped): restored by the next apply"
for f in ${FILES_SET}; do cp -p "${FILES}/${f}" "${FILES}/${f}.prev"; done
echo '{"started":"x"}' > "${FILES}/.trust-apply.pending"
echo "half written" > "${FILES}/${SERVER_JKS}"
assert_eq "apply: exit 0" "$(trust apply)" "0"
assert_contains "it says the change was interrupted" "$(cat "${WORK}/run.log")" "was interrupted"
assert_eq "the files are back" "$(sums ${FILES_SET})" "${good}"
assert_eq "the marker is gone" "$([[ -e "${FILES}/.trust-apply.pending" ]] && echo there || echo gone)" "gone"
echo "interrupted, and there is nothing to restore"
find "${FILES}" -name '*.prev' -delete
echo '{"started":"x"}' > "${FILES}/.trust-apply.pending"
assert_eq "apply: exit 1" "$(trust apply)" "1"
assert_eq "the marker stays" "$([[ -e "${FILES}/.trust-apply.pending" ]] && echo there || echo gone)" "there"
find "${FILES}/.trust-apply.pending" -delete

echo "a manifest that cannot be built"
cp "${FILES}/pki-state.json" "${WORK}/state-good.json"
trust_state() { jq "$1" "${FILES}/pki-state.json" > "${WORK}/s.json" && cp "${WORK}/s.json" "${FILES}/pki-state.json"; }
trust_state '.trust.entries |= map(select(.alias != "root-ca-01" and .alias != "intermediate-ca-01") | if .alias == "enrollment-ca-02" then .sets = ["server"] else . end)'
assert_eq "a set with no entries (phone): exit 1" "$(trust apply)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "would be empty"
cp "${WORK}/state-good.json" "${FILES}/pki-state.json"
trust_state '.trust.entries[0].file = "missing.pem"'
assert_eq "a certificate file that is missing: exit 1" "$(trust apply)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "missing.pem"
cp "${WORK}/state-good.json" "${FILES}/pki-state.json"
assert_eq "the files stayed as they were through these refusals" "$(sums ${FILES_SET})" "${good}"

echo "the signing keystore: a new generation"
openssl pkcs12 -export -in "${WORK}/cl2.pem" -inkey "${WORK}/cl2.key" -certfile <(cat "${FILES}/intermediate-ca.pem" "${FILES}/root-ca.pem") -name intermediate-ca -out "${WORK}/cl2.p12" -passout pass:atakatak 2> /dev/null
before_secret="$(state '.enrollmentSecret // "none"')"
assert_eq "before: the current secret is the one of the stack" "$(echo "${before_secret}")/$(state '.numbers.enrollment')" "none/1"
assert_eq "STUB_SECRET_WRITE_FAILS: install-signing exit 1" "$(STUB_SECRET_WRITE_FAILS=1 "${TRUST}" install-signing 2 "${WORK}/cl2.p12" > "${WORK}/run.log" 2>&1; echo $?)" "1"
assert_eq "...and the state is unchanged" "$(state '.enrollmentSecret // "none"')/$(state '.numbers.enrollment')" "none/1"
old_signer="$(sha256sum "${TMPFS}/intermediate-ca-signing.p12" | cut -c1-16)"
assert_eq "install-signing 2: exit 0" "$(trust install-signing 2 "${WORK}/cl2.p12")" "0"
assert_eq "the secret TAK-Test/TAK-Server/Enrollment-CA-02 holds the keystore" "$(cmp "${STUB_SECRETS}/TAK-Test_TAK-Server_Enrollment-CA-02" "${WORK}/cl2.p12" && echo same)" "same"
assert_eq "it is the current one, number 2" "$(state '.enrollmentSecret')/$(state '.numbers.enrollment')" "TAK-Test/TAK-Server/Enrollment-CA-02/2"
assert_eq "this node's tmpfs has the new keystore" "$(cmp "${TMPFS}/intermediate-ca-signing.p12" "${WORK}/cl2.p12" && echo same)" "same"
assert_eq "the JKS that TAK Server reads holds the new key and chain [Cl, S, R]" "$(aliases "${TMPFS}/intermediate-ca-signing.jks")/$(jks_fp "${TMPFS}/intermediate-ca-signing.jks" intermediate-ca)" "intermediate-ca/$(fp "${WORK}/cl2.pem")"
assert_eq "the chain in it has three certificates" "$(keytool -list -v -keystore "${TMPFS}/intermediate-ca-signing.jks" -storepass atakatak 2> /dev/null | grep 'Certificate chain length' | awk '{print $4}')" "3"
assert_eq "the EFS name is still a symlink into tmpfs" "$(readlink "${FILES}/intermediate-ca-signing.jks")" "${TMPFS}/intermediate-ca-signing.jks"
assert_eq "the old keystore secret is untouched" "$(ls "${STUB_SECRETS}" | grep -c 'Enrollment-CA$')" "1"
assert_eq "install-signing again with the same keystore: exit 0" "$(trust install-signing 2 "${WORK}/cl2.p12")" "0"
assert_contains "...it already holds it" "$(cat "${WORK}/run.log")" "already holds this keystore"
assert_eq "another keystore under the same number: exit 1, not overwritten" "$(trust install-signing 2 "${FILES}/admin.p12")" "1"
assert_eq "...the secret is unchanged" "$(cmp "${STUB_SECRETS}/TAK-Test_TAK-Server_Enrollment-CA-02" "${WORK}/cl2.p12" && echo same)" "same"
echo "a node that starts later restores the current generation"
find "${TMPFS}" -type f -delete
assert_eq "pki-bootstrap.sh (restore path): exit 0" "$("${BOOTSTRAP}" > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "the tmpfs keystore is generation 2, not the one of the stack" "$(cmp "${TMPFS}/intermediate-ca-signing.p12" "${WORK}/cl2.p12" && echo same)" "same"
assert_eq "the restore did not change the truststores or the manifest" "$(sums ${FILES_SET})/$(state '.trust.entries | length')" "${good}/4"

echo "destroying the key of a generation that is not in use any more"
: > "${STUB_LOG}/delete.log"; : > "${STUB_LOG}/aws.log"
assert_eq "retire-signing 2: refused, it is the current generation" "$(trust retire-signing 2)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "is the current one"
assert_eq "enrollment-ca-01 is in the manifest (the file of the stack)" "$(trust add enrollment-ca-01 "${FILES}/enrollment-ca.pem" server)" "0"
assert_eq "retire-signing 1: refused, Enrollment CA 01 is still trusted" "$(trust retire-signing 1)" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "still in the trust manifest"
assert_eq "retire-signing without a number or with a word: usage error" "$("${TRUST}" retire-signing x > /dev/null 2>&1; echo $?)/$("${TRUST}" retire-signing > /dev/null 2>&1; echo $?)" "64/64"
assert_eq "remove enrollment-ca-01 from the manifest" "$(trust remove enrollment-ca-01)" "0"
assert_eq "retire-signing 1: exit 0" "$(trust retire-signing 1)" "0"
assert_eq "the secret of the stack was overwritten twice (the current and the previous version)" "$(grep -c "put-secret-value --secret-id ${PKI_ENROLLMENT_CA_SECRET} " "${STUB_LOG}/aws.log")" "2"
assert_eq "it holds no keystore any more" "$(openssl pkcs12 -in "${STUB_SECRETS}/stack_TAK-Server_Enrollment-CA" -passin pass:atakatak -nokeys > /dev/null 2>&1 && echo keystore || echo none)" "none"
assert_eq "it is not deleted (a stack resource)" "$(wc -l < "${STUB_LOG}/delete.log")" "0"
assert_eq "install-signing 3 (the same keystore, for the test)" "$(trust install-signing 3 "${WORK}/cl2.p12")" "0"
assert_eq "the highest number is 3" "$(state .enrollmentHighest)" "3"
assert_eq "retire-signing 2: refused, enrollment-ca-02 is trusted" "$(trust retire-signing 2)" "1"
assert_eq "remove enrollment-ca-02 from the manifest" "$(trust remove enrollment-ca-02)" "0"
assert_eq "retire-signing 2: exit 0" "$(trust retire-signing 2)" "0"
assert_eq "its secret is deleted with a recovery window of 30 days, without force" "$(cat "${STUB_LOG}/delete.log")" "id=TAK-Test/TAK-Server/Enrollment-CA-02 window=30 force=0"
assert_eq "retire-signing 2 again: exit 0, already scheduled for deletion" "$(trust retire-signing 2)" "0"
assert_eq "...no second delete" "$(wc -l < "${STUB_LOG}/delete.log")" "1"
assert_eq "retire-signing 7: no such secret: exit 0" "$(trust retire-signing 7)" "0"
assert_eq "the current secret (3) is untouched" "$(cmp "${STUB_SECRETS}/TAK-Test_TAK-Server_Enrollment-CA-03" "${WORK}/cl2.p12" && echo same)" "same"
echo "a secret that cannot be read right after it was created"
export PKI_ROTATE_RETRY_DELAY=0
echo 2 > "${STUB_LOG}/read-fails"
assert_eq "the first two reads fail: install-signing 4 retries and succeeds" "$(trust install-signing 4 "${WORK}/cl2.p12")" "0"
: > "${STUB_LOG}/read-fails"
echo 50 > "${STUB_LOG}/read-fails"
assert_eq "the secret never reads back: install-signing 5 exit 1" "$(trust install-signing 5 "${WORK}/cl2.p12")" "1"
assert_contains "...it says that the next run continues with it" "$(cat "${WORK}/run.log")" "does not read back as written"
assert_eq "...the state still names generation 4" "$(state '.numbers.enrollment')" "4"
: > "${STUB_LOG}/read-fails"
assert_eq "...and the secret exists, so the next try finds it (same keystore: exit 0)" "$(trust install-signing 5 "${WORK}/cl2.p12")" "0"
echo "another node holds the lock"
mkdir -p "${FILES}/.locks"
printf 'other:1:1:1 60 othernode\n' > "${FILES}/.locks/pki-rotation.lock"
before="$(sums ${FILES_SET})"
assert_eq "apply: exit 75 after the wait" "$(CLUSTER_LOCK_WAIT=1 "${TRUST}" apply > "${WORK}/run.log" 2>&1; echo $?)" "75"
assert_eq "...nothing changed" "$(sums ${FILES_SET})" "${before}"

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
