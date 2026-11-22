#!/bin/bash
# Tests for docker-container/scripts/pki-crl-lib.sh and revoke-cert.sh (#204): a CRL for every Enrollment CA, and the
# revocation of single certificates.
#
# Same set-up as the other PKI tests (test/KmsCa/pki-harness.sh): SoftHSM2 tokens for the KMS keys, a stub `aws` for
# Secrets Manager, CloudWatch and ECS. Client certificates are signed with the real Enrollment CA key of each test stack.
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-pki-crl.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
REVOKE="${REPO_ROOT}/docker-container/scripts/revoke-cert.sh"
TRUST="${REPO_ROOT}/docker-container/scripts/pki-trust.sh"
CORECONFIG="${REPO_ROOT}/docker-container/scripts/createCoreConfig.sh"
export StackName=TAK-Test ECS_Cluster_Name=test-cluster ECS_Service_Name=test-service CLUSTER_LOCK_POLL=0.2 PKI_ROTATE_RETRY_DELAY=0

new_stack() { fresh "$1"; "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 || { echo "bootstrap failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }; }
revoke() { "${REVOKE}" "$@" > "${WORK}/run.log" 2>&1; echo $?; }
reset_log() { : > "${STUB_LOG}/metrics.log"; : > "${STUB_LOG}/ecs.log"; : > "${STUB_LOG}/aws.log"; }
metric_count() { grep -c -- "--metric-name $1 " "${STUB_LOG}/metrics.log"; }
ecs_count() { wc -l < "${STUB_LOG}/ecs.log"; }
crl() { echo "${FILES}/crl/$1.crl"; }
serials() { openssl crl -in "$1" -noout -text 2> /dev/null | grep "Serial Number:" | sed 's/.*Serial Number: //' | sort | tr '\n' ' ' | sed 's/ $//'; }
crl_verify() { openssl crl -in "$1" -CAfile "$2" -noout -verify 2>&1 | tail -1; }
crl_number() { openssl crl -in "$1" -noout -crlnumber 2> /dev/null | sed 's/crlNumber=//'; }
# a client certificate from an Enrollment CA: name cn serial ca-pem ca-p12
issue() { # name cn serial [p12 [capem]]
  local p12="${4:-${TMPFS}/intermediate-ca-signing.p12}" capem="${5:-${FILES}/enrollment-ca.pem}" k
  k="${WORK}/$1.cakey"
  openssl pkcs12 -in "${p12}" -passin pass:atakatak -nodes -nocerts -out "${k}" 2> /dev/null
  openssl genrsa -out "${WORK}/$1.key" 2048 2> /dev/null
  openssl req -new -key "${WORK}/$1.key" -subj "/O=TAK.NZ/CN=$2" -out "${WORK}/$1.csr"
  printf '[ client ]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=critical,clientAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' > "${WORK}/ext.cfg"
  openssl x509 -req -sha256 -days 30 -in "${WORK}/$1.csr" -CA "${capem}" -CAkey "${k}" -set_serial "$3" -extensions client -extfile "${WORK}/ext.cfg" -out "${WORK}/$1.pem" > /dev/null 2>&1
  find "${k}" -delete
}
no_leftovers() { ls "${TMPFS}" | grep -c -e '^crl-' ; }

echo "setup: a first-boot PKI"
new_stack main
reset_log

echo "the CRL of a new PKI"
assert_file "a CRL for Enrollment CA 01" "$(crl enrollment-ca-01)"
assert_eq "it is PEM" "$(head -1 "$(crl enrollment-ca-01)")" "-----BEGIN X509 CRL-----"
assert_eq "signed by Enrollment CA 01" "$(crl_verify "$(crl enrollment-ca-01)" "${FILES}/enrollment-ca.pem")" "verify OK"
assert_eq "issued by that CA" "$(openssl crl -in "$(crl enrollment-ca-01)" -noout -issuer -nameopt RFC2253)" "issuer=CN=TAK.NZ Try Enrollment CA 01,O=TAK.NZ"
assert_eq "empty" "$(serials "$(crl enrollment-ca-01)")" ""
next="$(date -d "$(openssl crl -in "$(crl enrollment-ca-01)" -noout -nextupdate | cut -d= -f2)" +%s)"
assert_eq "valid for 365 days (TAK Server ignores nextUpdate, #204, but other tools do not)" "$(( (next - $(date +%s)) / 86400 >= 364 && (next - $(date +%s)) / 86400 <= 365 ))" "1"
assert_eq "the CRL is world readable (it is public), no key is on the EFS under crl/" "$(stat -c %a "$(crl enrollment-ca-01)")/$(grep -rl 'PRIVATE KEY' "${FILES}/crl" | wc -l)" "644/0"
assert_eq "the database of the CA is there (index, serial numbers, no key)" "$(ls "${FILES}/crl/db/enrollment-ca-01" | grep -c -e '^index.txt$' -e '^crlnumber$' -e '^serial$')" "3"
assert_eq "--list shows nothing revoked" "$(revoke --list)/$(grep -c 'nothing revoked' "${WORK}/run.log")" "0/1"
assert_eq "00-all.crl holds the CRL of every Enrollment CA (TAK Server's API reads only the first <crl>, #135)" "$(cmp "${FILES}/crl/00-all.crl" "$(crl enrollment-ca-01)" && echo same)/$(stat -c %a "${FILES}/crl/00-all.crl")" "same/644"

echo "revoking a certificate by file"
issue x "admin" 0xA001
issue y "admin" 0xA002
issue z "crltest" 0xB003
before_num="$(crl_number "$(crl enrollment-ca-01)")"
assert_eq "revoke-cert.sh x.pem: exit 0" "$(revoke "${WORK}/x.pem")" "0"
assert_eq "the CRL lists exactly that serial (not the second certificate with the same CN)" "$(serials "$(crl enrollment-ca-01)")" "A001"
assert_eq "still signed by Enrollment CA 01" "$(crl_verify "$(crl enrollment-ca-01)" "${FILES}/enrollment-ca.pem")" "verify OK"
assert_eq "the CRL number went up" "$(( $(crl_number "$(crl enrollment-ca-01)") > before_num ))" "1"
assert_contains "the revocation carries the reason" "$(openssl crl -in "$(crl enrollment-ca-01)" -noout -text)" "Unspecified"
assert_eq "the index has the revoked certificate" "$(awk -F'\t' '$1 == "R" {print $4 " " $6}' "${FILES}/crl/db/enrollment-ca-01/index.txt")" "A001 /O=TAK.NZ/CN=admin"
assert_eq "TAK Server reads CRLs only at start: one rolling deployment" "$(ecs_count)" "1"
assert_eq "CertificateRevoked emitted once" "$(metric_count CertificateRevoked)" "1"
assert_eq "the key was in tmpfs only for the signing: nothing left" "$(no_leftovers)" "0"
assert_eq "the lock is released" "$([[ -e "${FILES}/.locks/pki-rotation.lock" ]] && echo held || echo free)" "free"
assert_eq "--list shows it" "$(revoke --list)/$(grep -c 'serial A001' "${WORK}/run.log")" "0/1"
echo "again: nothing to do"
reset_log
sum="$(sha256sum "$(crl enrollment-ca-01)" | cut -c1-16)"
assert_eq "revoke-cert.sh x.pem again: exit 0" "$(revoke "${WORK}/x.pem")" "0"
assert_contains "it says it is revoked already" "$(cat "${WORK}/run.log")" "is revoked in the CRL of enrollment-ca-01 already"
assert_eq "the CRL is unchanged, no deployment, no metric" "$(sha256sum "$(crl enrollment-ca-01)" | cut -c1-16)/$(ecs_count)/$(metric_count CertificateRevoked)" "${sum}/0/0"
echo "--no-restart and a reason"
assert_eq "revoke y --reason keyCompromise --no-restart: exit 0" "$(revoke "${WORK}/y.pem" --reason keyCompromise --no-restart)" "0"
assert_eq "the CRL lists both" "$(serials "$(crl enrollment-ca-01)")" "A001 A002"
assert_contains "the reason is in the CRL" "$(openssl crl -in "$(crl enrollment-ca-01)" -noout -text)" "Key Compromise"
assert_eq "no deployment" "$(ecs_count)" "0"
assert_contains "the log says when it is in force" "$(cat "${WORK}/run.log")" "in force after the next start"
assert_eq "the metric is emitted" "$(metric_count CertificateRevoked)" "1"
echo "by serial, for a certificate that is not at hand"
assert_eq "revoke-cert.sh --serial: exit 0" "$(revoke --serial beef --ca enrollment-ca-01 --subject /O=TAK.NZ/CN=lost --not-after "$(date -u -d '+20 days' '+%b %e %H:%M:%S %Y GMT')" --no-restart)" "0"
assert_eq "serial BEEF is in the CRL" "$(serials "$(crl enrollment-ca-01)")" "A001 A002 BEEF"
assert_eq "a serial with an odd number of digits is written with an even number" "$(revoke --serial abc --ca enrollment-ca-01 --subject /O=TAK.NZ/CN=odd --not-after "$(date -u -d '+20 days' '+%b %e %H:%M:%S %Y GMT')" --no-restart)/$(serials "$(crl enrollment-ca-01)")" "0/0ABC A001 A002 BEEF"

echo "what is refused"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/foreign.key" -out "${WORK}/foreign.pem" -subj "/CN=Foreign client" -days 30 2> /dev/null
before="$(sha256sum "$(crl enrollment-ca-01)" | cut -c1-16)"
assert_eq "a certificate of another CA: exit 1" "$(revoke "${WORK}/foreign.pem")" "1"
assert_contains "...with a reason" "$(cat "${WORK}/run.log")" "was not issued by an Enrollment CA of this stack"
assert_eq "a file that is no certificate: exit 1" "$(revoke "${WORK}/bootstrap.log")" "1"
assert_eq "an unknown reason: exit 1" "$(revoke --serial 1234 --ca enrollment-ca-01 --subject /CN=x --not-after 'Dec 31 23:59:59 2030 GMT' --reason because)" "1"
assert_eq "an invalid serial: exit 1" "$(revoke --serial xyz --ca enrollment-ca-01 --subject /CN=x --not-after 'Dec 31 23:59:59 2030 GMT')" "1"
assert_eq "an invalid CA alias: exit 1" "$(revoke --serial 1234 --ca root-ca-01 --subject /CN=x --not-after 'Dec 31 23:59:59 2030 GMT')" "1"
assert_eq "an Enrollment CA that is not in the manifest: exit 1" "$(revoke --serial 1234 --ca enrollment-ca-09 --subject /CN=x --not-after 'Dec 31 23:59:59 2030 GMT')" "1"
assert_eq "an unreadable date: exit 1" "$(revoke --serial 1234 --ca enrollment-ca-01 --subject /CN=x --not-after nonsense)" "1"
assert_eq "no arguments: exit 64" "$(revoke)" "64"
assert_eq "an incomplete --serial call: exit 64" "$(revoke --serial 1234)" "64"
assert_eq "none of this changed the CRL" "$(sha256sum "$(crl enrollment-ca-01)" | cut -c1-16)" "${before}"
echo "a signing that fails leaves the CRL and the database as they were"
idx="$(sha256sum "${FILES}/crl/db/enrollment-ca-01/index.txt" | cut -c1-16)"
# the tmpfs keystore is the key of the current generation; take it away and the secret does not exist either
mv "${TMPFS}/intermediate-ca-signing.p12" "${WORK}/signer.p12"
assert_eq "no key in tmpfs and no secret: exit 1" "$(PKI_ENROLLMENT_CA_SECRET=does-not-exist revoke "${WORK}/z.pem" --no-restart)" "1"
mv "${WORK}/signer.p12" "${TMPFS}/intermediate-ca-signing.p12"
assert_eq "the CRL and the index are unchanged" "$(sha256sum "$(crl enrollment-ca-01)" "${FILES}/crl/db/enrollment-ca-01/index.txt" | cut -c1-16 | tr '\n' ' ')" "${before} ${idx} "
# a key that does not belong to the CA: openssl signs, the check of the new CRL fails, and the database must go back
openssl pkcs12 -export -in "${WORK}/foreign.pem" -inkey "${WORK}/foreign.key" -name intermediate-ca -out "${WORK}/wrong.p12" -passout pass:atakatak 2> /dev/null
cp -p "${TMPFS}/intermediate-ca-signing.p12" "${WORK}/signer.good"
cp "${WORK}/wrong.p12" "${TMPFS}/intermediate-ca-signing.p12"
num="$(cat "${FILES}/crl/db/enrollment-ca-01/crlnumber")"
assert_eq "a signing key that does not match the CA: exit 1" "$(revoke "${WORK}/z.pem" --no-restart)" "1"
assert_contains "...the log says the previous CRL is kept" "$(cat "${WORK}/run.log")" "the previous CRL is kept"
assert_eq "...the index is back as it was, the CRL is unchanged" "$(sha256sum "$(crl enrollment-ca-01)" "${FILES}/crl/db/enrollment-ca-01/index.txt" | cut -c1-16 | tr '\n' ' ')" "${before} ${idx} "
assert_eq "...the CRL number is back too" "$(cat "${FILES}/crl/db/enrollment-ca-01/crlnumber")" "${num}"
assert_eq "...and nothing is left in tmpfs or next to the CRL" "$(no_leftovers)/$(ls "${FILES}/crl" | grep -c '\.new$')" "0/0"
cp -p "${WORK}/signer.good" "${TMPFS}/intermediate-ca-signing.p12"
assert_eq "with the right key again the revocation works" "$(revoke "${WORK}/z.pem" --no-restart)/$(serials "$(crl enrollment-ca-01)")" "0/0ABC A001 A002 B003 BEEF"

echo "the restore path"
new_stack restore
assert_eq "bootstrap created the CRL" "$([[ -s "$(crl enrollment-ca-01)" ]] && echo yes)" "yes"
find "${FILES}/crl" -delete
reset_log
assert_eq "a start without CRLs (a PKI from before #204): exit 0" "$("${BOOTSTRAP}" > "${WORK}/run.log" 2>&1; echo $?)" "0"
assert_eq "the empty CRL is back, signed by Enrollment CA 01" "$(serials "$(crl enrollment-ca-01)")/$(crl_verify "$(crl enrollment-ca-01)" "${FILES}/enrollment-ca.pem")" "/verify OK"
assert_contains "the log says CoreConfig gets it at the next start" "$(cat "${WORK}/run.log")" "CoreConfig.xml gets it at the next start"
assert_eq "...and the combined file is back" "$(cmp "${FILES}/crl/00-all.crl" "$(crl enrollment-ca-01)" && echo same)" "same"
before="$(sha256sum "$(crl enrollment-ca-01)" "${FILES}/crl/00-all.crl" | cut -c1-16 | tr '\n' ' ')"
"${BOOTSTRAP}" > /dev/null 2>&1
assert_eq "a start with a CRL leaves it and the combined file alone" "$(sha256sum "$(crl enrollment-ca-01)" "${FILES}/crl/00-all.crl" | cut -c1-16 | tr '\n' ' ')" "${before}"
find "${FILES}/crl/00-all.crl" -delete
reset_log
"${BOOTSTRAP}" > "${WORK}/run.log" 2>&1
assert_eq "a start without the combined file (a stack from before it) writes it" "$(cmp "${FILES}/crl/00-all.crl" "$(crl enrollment-ca-01)" && echo same)" "same"

echo "a second Enrollment CA: revocation goes to the CRL of the CA that issued the certificate"
new_stack gen
issue old "admin" 0xC001
openssl genrsa -out "${WORK}/cl2.key" 2048 2> /dev/null
openssl req -new -key "${WORK}/cl2.key" -subj "/O=TAK.NZ/CN=TAK.NZ Try Enrollment CA 02" -out "${WORK}/cl2.csr"
"${PKI_KMS_CA_SCRIPT}" issue-ca intermediate-ca-01 "${FILES}/intermediate-ca.pem" "${WORK}/cl2.csr" "${WORK}/cl2.pem" 1000 > /dev/null
openssl pkcs12 -export -in "${WORK}/cl2.pem" -inkey "${WORK}/cl2.key" -certfile <(cat "${FILES}/intermediate-ca.pem" "${FILES}/root-ca.pem") -name intermediate-ca -out "${WORK}/cl2.p12" -passout pass:atakatak 2> /dev/null
"${TRUST}" add enrollment-ca-02 "${WORK}/cl2.pem" server > /dev/null 2>&1
"${TRUST}" install-signing 2 "${WORK}/cl2.p12" > /dev/null 2>&1
assert_eq "generation 2 is current" "$(jq -r .numbers.enrollment "${FILES}/pki-state.json")" "2"
"${BOOTSTRAP}" > "${WORK}/run.log" 2>&1
assert_eq "a start creates the empty CRL of Enrollment CA 02" "$([[ -s "$(crl enrollment-ca-02)" ]] && echo yes)/$(serials "$(crl enrollment-ca-02)")/$(crl_verify "$(crl enrollment-ca-02)" "${FILES}/trust-certs/enrollment-ca-02.pem")" "yes//verify OK"
assert_eq "the combined file holds both, 01 first" "$(cmp "${FILES}/crl/00-all.crl" <(cat "$(crl enrollment-ca-01)" "$(crl enrollment-ca-02)") && echo same)" "same"
issue new "admin" 0xD001 "${TMPFS}/intermediate-ca-signing.p12" "${FILES}/trust-certs/enrollment-ca-02.pem"
reset_log
assert_eq "revoke a certificate of the OLD Enrollment CA (its key comes from its secret): exit 0" "$(revoke "${WORK}/old.pem" --no-restart)" "0"
assert_eq "CRL 01 has it, CRL 02 does not" "$(serials "$(crl enrollment-ca-01)")/$(serials "$(crl enrollment-ca-02)")" "C001/"
assert_eq "CRL 01 is still signed by Enrollment CA 01" "$(crl_verify "$(crl enrollment-ca-01)" "${FILES}/enrollment-ca.pem")" "verify OK"
assert_eq "revoke a certificate of the CURRENT Enrollment CA: exit 0" "$(revoke "${WORK}/new.pem" --no-restart)" "0"
assert_eq "CRL 02 has it, signed by Enrollment CA 02" "$(serials "$(crl enrollment-ca-02)")/$(crl_verify "$(crl enrollment-ca-02)" "${FILES}/trust-certs/enrollment-ca-02.pem")" "D001/verify OK"
assert_eq "CRL 01 is untouched by that" "$(serials "$(crl enrollment-ca-01)")" "C001"
assert_eq "the combined file follows both revocations" "$(cmp "${FILES}/crl/00-all.crl" <(cat "$(crl enrollment-ca-01)" "$(crl enrollment-ca-02)") && echo same)/$(grep -c 'BEGIN X509 CRL' "${FILES}/crl/00-all.crl")" "same/2"
assert_eq "the old CA's key was read from a secret and removed again" "$(no_leftovers)" "0"
assert_eq "--list shows both CAs" "$(revoke --list)/$(grep -c -e '^enrollment-ca-01' -e '^enrollment-ca-02' "${WORK}/run.log")" "0/2"

echo "CoreConfig.xml"
export PostgresUsername=u PostgresPassword=p PostgresURL="postgresql://localhost:5432/db" TAK_VERSION="takserver-docker-5.8-RELEASE-103" \
  LDAP_DN="dc=example,dc=com" LDAP_SECURE_URL="ldaps://ldap.example.com:636" LDAP_Password=l
for v in 5.4-RELEASE-19 5.5-RELEASE-1 5.8-RELEASE-103; do
  out="${WORK}/CoreConfig-${v}.xml"
  env TAK_VERSION="takserver-docker-${v}" TAK_CRL_DIR="${FILES}/crl" bash "${CORECONFIG}" "${out}" > "${WORK}/cc.log" 2>&1
  tls="$(grep -A1 '<security>' "${out}" | tr -d '\n')"
  assert_eq "${v}: <security><tls> holds a <crl> for the combined file (first) and for each of the two CRL files" "$(grep -o '<crl _name="[^"]*" crlFile="[^"]*"/>' <<< "${tls}" | sed 's/crlFile="[^"]*"//' | tr '\n' ' ')" '<crl _name="00-all" /> <crl _name="enrollment-ca-01" /> <crl _name="enrollment-ca-02" /> '
  assert_contains "${v}: the file path is the CRL file" "${tls}" "crlFile=\"${FILES}/crl/enrollment-ca-01.crl\""
  assert_not_contains "${v}: the placeholder is gone" "$(cat "${out}")" "{{CRL_ELEMENTS}}"
done
env TAK_CRL_DIR="${WORK}/no-such-dir" bash "${CORECONFIG}" "${WORK}/CoreConfig-none.xml" > /dev/null 2>&1
assert_eq "without CRL files the <tls> element is empty" "$(grep -A1 '<security>' "${WORK}/CoreConfig-none.xml" | grep -c '<crl')" "0"
assert_contains "...and still closed" "$(grep -A1 '<security>' "${WORK}/CoreConfig-none.xml" | tr -d '\n')" "keymanager=\"SunX509\"></tls>"
XSD="${REPO_ROOT}/test/CoreConfig/CoreConfig.xsd"
if command -v xmllint > /dev/null && [[ -f "${XSD}" ]]; then
  xmllint --noout --schema "${XSD}" "${WORK}/CoreConfig-5.8-RELEASE-103.xml" > "${WORK}/xsd.log" 2>&1
  assert_eq "the CoreConfig with CRLs is valid against the CoreConfig.xsd of TAK Server" "$?" "0"
else
  echo "  skip xmllint or CoreConfig.xsd not available"
fi

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
