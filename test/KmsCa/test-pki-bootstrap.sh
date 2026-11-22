#!/bin/bash
# Tests for docker-container/scripts/pki-bootstrap.sh (#189).
#
# Same approach as test-kms-ca.sh: SoftHSM2 tokens stand in for the two KMS keys, and a stub `aws`
# command stands in for Secrets Manager (it keeps secret values as files). Needs: openssl 3 with the
# libp11 "pkcs11" engine, softhsm2, opensc (pkcs11-tool), jq, keytool.
#   Ubuntu: sudo apt-get install -y softhsm2 opensc libengine-pkcs11-openssl jq default-jre-headless
# Run from the repository root:  test/KmsCa/test-pki-bootstrap.sh
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
SCRIPT="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
run() { "${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?; }
rc_is() { local d="$1" want="$2" got; got="$(run)"; assert_eq "${d}" "${got}" "${want}"; }
subject() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'; }
ks_aliases() { keytool -list -keystore "$1" -storepass atakatak 2> /dev/null | grep -E 'trustedCertEntry|PrivateKeyEntry' | cut -d, -f1 | sort | tr '\n' ' ' | sed 's/ $//'; }
chain_len() { keytool -list -v -keystore "$1" -storepass atakatak 2> /dev/null | grep 'Certificate chain length' | awk '{print $4}'; }

# --- not applicable ---------------------------------------------------------------------------
echo "not applicable"
fresh na
( export PKI_KMS_CA_KEYS=""; rc="$("${SCRIPT}" > /dev/null 2>&1; echo $?)"; [[ "${rc}" == 2 ]] ) && pass "empty PKI_KMS_CA_KEYS gives exit code 2" || fail "empty PKI_KMS_CA_KEYS gives exit code 2"
fresh legacy
echo "legacy" > "${FILES}/ca.pem"
rc_is "a stack with an old-flow PKI (ca.pem, no state file) is left alone" 2
assert_eq "old-flow files untouched" "$(cat "${FILES}/ca.pem")" "legacy"
assert_no_file "no state file written" "${FILES}/pki-state.json"

# --- bad settings ----------------------------------------------------------------------------
echo "settings"
fresh bad
( export PKI_ROOT_DAYS=100 PKI_INTERMEDIATE_DAYS=200; rc="$("${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?)"; [[ "${rc}" == 1 ]] && grep -q "validities must satisfy" "${WORK}/run.log" ) && pass "a child that outlives its issuer is refused" || fail "a child that outlives its issuer is refused" "$(tail -2 "${WORK}/run.log")"
( export P12_PROFILE=rc2; "${SCRIPT}" > "${WORK}/run.log" 2>&1; [[ $? == 1 ]] && grep -q "P12_PROFILE must be" "${WORK}/run.log" ) && pass "unknown P12_PROFILE is refused" || fail "unknown P12_PROFILE is refused"
( export PKI_SERVER_NAMES='ops.try.tak.nz,evil;id'; "${SCRIPT}" > "${WORK}/run.log" 2>&1; [[ $? == 1 ]] && grep -q "invalid server name" "${WORK}/run.log" ) && pass "server names are validated" || fail "server names are validated"
( export PKI_KMS_CA_KEYS="root-ca-01=11111111-1111-4111-8111-111111111111"; "${SCRIPT}" > "${WORK}/run.log" 2>&1; [[ $? == 1 ]] && grep -q "no intermediate-ca-01" "${WORK}/run.log" ) && pass "a missing KMS slot is refused" || fail "a missing KMS slot is refused"
( export PKI_ENV_LABEL='Try/../x'; "${SCRIPT}" > "${WORK}/run.log" 2>&1; [[ $? == 1 ]] ) && pass "an invalid environment label is refused" || fail "an invalid environment label is refused"
assert_no_file "nothing installed after refused runs" "${FILES}/takserver.jks"

# --- first boot -------------------------------------------------------------------------------
echo "bootstrap"
fresh a
rc_is "first boot succeeds" 0
for f in root-ca.pem intermediate-ca.pem enrollment-ca.pem ca.pem takserver.pem takserver.key takserver.jks takserver.p12 \
         admin.p12 admin.pem admin.key truststore-intermediate-ca.jks truststore-intermediate-ca.p12 truststore-phone.jks truststore-phone.p12 \
         fed-truststore.jks pki-state.json; do
  assert_file "created ${f}" "${FILES}/${f}"
done
echo "-- no CA private key on the EFS"
assert_no_file "no root key file" "${FILES}/root-ca-do-not-share.key"
assert_no_file "no intermediate key file" "${FILES}/ca-do-not-share.key"
assert_no_file "no Enrollment CA key file" "${FILES}/enrollment-ca.key"
keys="$(grep -l "PRIVATE KEY" "${FILES}"/* 2> /dev/null | xargs -n1 basename 2> /dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the only PEM private keys on the EFS are the server and admin keys" "${keys}" "admin.key takserver.key"
assert_eq "the signing keystore on the EFS is a symlink" "$([[ -L "${FILES}/intermediate-ca-signing.jks" ]] && echo yes)" "yes"
assert_eq "it points into tmpfs" "$(readlink "${FILES}/intermediate-ca-signing.jks")" "${TMPFS}/intermediate-ca-signing.jks"
assert_file "the tmpfs signing keystore exists" "${TMPFS}/intermediate-ca-signing.jks"
assert_eq "tmpfs directory is private" "$(stat -c %a "${TMPFS}")" "700"
assert_eq "no work directory left behind" "$(ls "${TMPFS}" | grep -c '^work\.')" "0"
assert_eq "the lock is released" "$([[ -e "${FILES}/.locks/pki-bootstrap.lock" ]] && echo held || echo free)" "free"

echo "-- file modes"
mode() { stat -c %a "${FILES}/$1"; }
for f in root-ca.pem intermediate-ca.pem enrollment-ca.pem ca.pem takserver.pem admin.pem takserver.jks truststore-intermediate-ca.jks truststore-phone.p12 fed-truststore.jks pki-state.json; do
  assert_eq "${f} is world-readable" "$(mode "${f}")" "644"
done
for f in takserver.key admin.key admin.p12 takserver.p12; do
  assert_eq "${f} is private" "$(mode "${f}")" "600"
done

echo "-- names and constraints"
assert_eq "root subject" "$(subject "${FILES}/root-ca.pem")" "CN=TAK.NZ Try Root CA 01,O=TAK.NZ"
assert_eq "intermediate subject" "$(subject "${FILES}/intermediate-ca.pem")" "CN=TAK.NZ Try Intermediate CA 01,O=TAK.NZ"
assert_eq "enrollment CA subject" "$(subject "${FILES}/enrollment-ca.pem")" "CN=TAK.NZ Try Enrollment CA 01,O=TAK.NZ"
assert_contains "root pathlen 3" "$(openssl x509 -in "${FILES}/root-ca.pem" -noout -ext basicConstraints)" "pathlen:3"
assert_contains "intermediate pathlen 2" "$(openssl x509 -in "${FILES}/intermediate-ca.pem" -noout -ext basicConstraints)" "pathlen:2"
assert_contains "enrollment CA pathlen 0" "$(openssl x509 -in "${FILES}/enrollment-ca.pem" -noout -ext basicConstraints)" "pathlen:0"
ski() { openssl x509 -in "${FILES}/$1.pem" -noout -ext subjectKeyIdentifier | tail -1 | tr -d ' '; }
aki() { openssl x509 -in "${FILES}/$1.pem" -noout -ext authorityKeyIdentifier | tr -d ' \n'; }
# key-id based: the authority key identifier is the issuer's subject key identifier, with no issuer name or serial number
for pair in "intermediate-ca root-ca" "enrollment-ca intermediate-ca" "takserver intermediate-ca"; do
  set -- ${pair}
  assert_contains "$1: authority key id is the key id of $2" "$(aki "$1")" "$(ski "$2")"
  assert_not_contains "$1: authority key id has no issuer name or serial number" "$(aki "$1")" "serial"
done
assert_eq "ca.pem is the issuing intermediate certificate" "$(cmp -s "${FILES}/ca.pem" "${FILES}/intermediate-ca.pem" && echo same)" "same"

echo "-- server certificate"
assert_eq "server CN is the first name" "$(subject "${FILES}/takserver.pem")" "CN=ops.try.tak.nz,O=TAK.NZ"
SAN="$(openssl x509 -in "${FILES}/takserver.pem" -noout -ext subjectAltName | tr -d ' \n')"
assert_contains "SAN has takserver" "${SAN}" "DNS:takserver"
assert_contains "SAN has the service name" "${SAN}" "DNS:ops.try.tak.nz"
assert_contains "SAN has the TAK host name" "${SAN}" "DNS:tak.try.tak.nz"
assert_contains "server certificate can be a server and a client" "$(openssl x509 -in "${FILES}/takserver.pem" -noout -ext extendedKeyUsage | tr -d '\n')" "TLS Web Server Authentication"
assert_eq "hostname check passes for the service name" "$(openssl verify -CAfile "${FILES}/root-ca.pem" -untrusted "${FILES}/intermediate-ca.pem" -verify_hostname ops.try.tak.nz "${FILES}/takserver.pem" 2>&1 | tail -1 | sed 's/.*: //')" "OK"
assert_eq "hostname check fails for another name" "$(openssl verify -CAfile "${FILES}/root-ca.pem" -untrusted "${FILES}/intermediate-ca.pem" -verify_hostname wrong.try.tak.nz "${FILES}/takserver.pem" > /dev/null 2>&1 && echo ok || echo fails)" "fails"

echo "-- strict chains"
assert_eq "server cert: R -> S -> L" "$(openssl verify -CAfile "${FILES}/root-ca.pem" -untrusted "${FILES}/intermediate-ca.pem" "${FILES}/takserver.pem" 2>&1 | tail -1 | sed 's/.*: //')" "OK"
assert_eq "admin cert: R -> S -> Cl -> admin" "$(openssl verify -CAfile "${FILES}/root-ca.pem" -untrusted <(cat "${FILES}/intermediate-ca.pem" "${FILES}/enrollment-ca.pem") <(openssl x509 -in "${FILES}/admin.pem") 2>&1 | tail -1 | sed 's/.*: //')" "OK"
assert_eq "admin CN" "$(openssl x509 -in "${FILES}/admin.pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')" "CN=admin,O=TAK.NZ"

echo "-- keystores and truststores"
assert_eq "signing keystore chain is [Cl, S, R]" "$(chain_len "${FILES}/intermediate-ca-signing.jks")" "3"
assert_eq "signing keystore leads with the Enrollment CA" "$(keytool -list -v -keystore "${FILES}/intermediate-ca-signing.jks" -storepass atakatak 2> /dev/null | grep -m1 'Owner:' | sed 's/Owner: //')" "CN=TAK.NZ Try Enrollment CA 01, O=TAK.NZ"
assert_eq "server keystore chain is [L, S, R]" "$(chain_len "${FILES}/takserver.jks")" "3"
assert_eq "server truststore holds R, S and the Enrollment CA" "$(ks_aliases "${FILES}/truststore-intermediate-ca.jks")" "enrollment-ca-01 intermediate-ca-01 root-ca-01"
assert_eq "phone truststore holds only S and R" "$(ks_aliases "${FILES}/truststore-phone.jks")" "intermediate-ca-01 root-ca-01"
assert_eq "phone truststore p12 holds only S and R (trusted certificate entries)" "$(keytool -list -keystore "${FILES}/truststore-phone.p12" -storetype PKCS12 -storepass atakatak 2> /dev/null | grep -c trustedCertEntry)" "2"
assert_eq "federation truststore holds S and R" "$(ks_aliases "${FILES}/fed-truststore.jks")" "intermediate-ca-01 root-ca-01"
assert_eq "admin.pem and admin.key are a pair (the health check uses them)" \
  "$([[ "$(openssl x509 -in "${FILES}/admin.pem" -noout -pubkey | sha256sum)" == "$(openssl rsa -in "${FILES}/admin.key" -passin pass:atakatak -pubout 2> /dev/null | sha256sum)" ]] && echo pair)" "pair"

echo "-- PKCS#12 profile (default compat3des) readable by OpenSSL 3 without the legacy provider"
assert_eq "admin.p12 reads with the default provider" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -noout > /dev/null 2>&1 && echo ok)" "ok"
assert_contains "admin.p12 uses 3DES, not RC2" "$(openssl pkcs12 -legacy -in "${FILES}/admin.p12" -passin pass:atakatak -info -noout 2>&1)" "TripleDES"
assert_not_contains "admin.p12 has no RC2" "$(openssl pkcs12 -legacy -in "${FILES}/admin.p12" -passin pass:atakatak -info -noout 2>&1)" "RC2"

echo "-- Secrets Manager"
SECRET="${STUB_SECRETS}/stack_TAK-Server_Enrollment-CA"
assert_file "the signing keystore is in the secret" "${SECRET}"
assert_eq "the secret holds [Cl, S, R] with a key" "$(keytool -list -v -keystore "${SECRET}" -storetype PKCS12 -storepass atakatak 2> /dev/null | grep -c 'Entry type: PrivateKeyEntry')" "1"

echo "-- state file"
assert_eq "state version" "$(jq -r .version "${FILES}/pki-state.json")" "1"
assert_eq "state records the names" "$(jq -r '.names.enrollment' "${FILES}/pki-state.json")" "TAK.NZ Try Enrollment CA 01"
assert_eq "state records the SAN" "$(jq -r '.names.serverSan' "${FILES}/pki-state.json")" "DNS:takserver,DNS:ops.try.tak.nz,DNS:tak.try.tak.nz"
assert_contains "state records expiry dates for the orchestrator" "$(jq -r '.notAfter.root' "${FILES}/pki-state.json")" "GMT"
ROOT_END_YEAR="$(openssl x509 -in "${FILES}/root-ca.pem" -noout -enddate | awk '{print $4}')"
assert_eq "root is valid for about 20 years" "$(( ROOT_END_YEAR - $(date +%Y) ))" "20"

# --- later start: restore -------------------------------------------------------------------
echo "restore on a later start"
FP_BEFORE="$(sha256sum "${FILES}/takserver.pem" "${FILES}/root-ca.pem" "${FILES}/admin.p12" | awk '{print $1}' | tr '\n' ' ')"
find "${TMPFS}" -delete   # a new container has an empty tmpfs
rc_is "restart restores the signing keystore" 0
assert_eq "the certificates are unchanged" "$(sha256sum "${FILES}/takserver.pem" "${FILES}/root-ca.pem" "${FILES}/admin.p12" | awk '{print $1}' | tr '\n' ' ')" "${FP_BEFORE}"
assert_eq "the signing keystore is back in tmpfs with its chain" "$(chain_len "${FILES}/intermediate-ca-signing.jks")" "3"
assert_eq "tmpfs directory is private again" "$(stat -c %a "${TMPFS}")" "700"

echo "fail closed"
mv "${SECRET}" "${SECRET}.gone"
find "${TMPFS}" -delete
rc_is "a missing secret stops the start" 1
assert_contains "the message says so" "$(cat "${WORK}/run.log")" "cannot read secret"
assert_eq "no second PKI is generated" "$(sha256sum "${FILES}/takserver.pem" "${FILES}/root-ca.pem" "${FILES}/admin.p12" | awk '{print $1}' | tr '\n' ' ')" "${FP_BEFORE}"
mv "${SECRET}.gone" "${SECRET}"
mv "${FILES}/takserver.jks" "${FILES}/takserver.jks.gone"
rc_is "a missing PKI file with a state file stops the start" 1
assert_contains "the message names the file" "$(cat "${WORK}/run.log")" "takserver.jks is missing"
mv "${FILES}/takserver.jks.gone" "${FILES}/takserver.jks"
rc_is "and works again once it is back" 0

echo "a failed secret write installs nothing"
fresh b
( export STUB_SECRET_WRITE_FAILS=1; rc="$("${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $?)"; [[ "${rc}" == 1 ]] ) && pass "exit code 1" || fail "exit code 1"
assert_no_file "no takserver keystore installed" "${FILES}/takserver.jks"
assert_no_file "no state file" "${FILES}/pki-state.json"
rc_is "the next start can bootstrap" 0

# --- aes256 profile ---------------------------------------------------------------------------
echo "P12_PROFILE=aes256"
fresh c
( export P12_PROFILE=aes256; "${SCRIPT}" > "${WORK}/run.log" 2>&1 ) && pass "bootstraps with aes256" || fail "bootstraps with aes256" "$(tail -3 "${WORK}/run.log")"
assert_contains "admin.p12 uses AES-256" "$(openssl pkcs12 -in "${FILES}/admin.p12" -passin pass:atakatak -info -noout 2>&1)" "AES-256-CBC"

# --- custom validities -----------------------------------------------------------------------
echo "validities are settings"
fresh d
( export PKI_ROOT_DAYS=3000 PKI_INTERMEDIATE_DAYS=2000 PKI_ENROLLMENT_CA_DAYS=900 PKI_SERVER_CERT_DAYS=300 PKI_ADMIN_CERT_DAYS=200; "${SCRIPT}" > "${WORK}/run.log" 2>&1 ) && pass "bootstraps with custom validities" || fail "bootstraps with custom validities" "$(tail -3 "${WORK}/run.log")"
days() { echo $(( ( $(date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 )); }
assert_eq "root validity" "$(days "${FILES}/root-ca.pem")" "2999"
assert_eq "intermediate validity" "$(days "${FILES}/intermediate-ca.pem")" "1999"
assert_eq "enrollment CA validity" "$(days "${FILES}/enrollment-ca.pem")" "899"
assert_eq "server certificate validity" "$(days "${FILES}/takserver.pem")" "299"

# --- several nodes on a fresh stack (#7) -----------------------------------------------------
echo "three nodes start at the same time on a fresh stack"
fresh e
for n in 1 2 3; do
  ( export PKI_TMPFS_DIR="${WORK}/e/tmpfs-node${n}"; "${SCRIPT}" > "${WORK}/node${n}.log" 2>&1; echo $? > "${WORK}/node${n}.rc" ) &
done
wait
assert_eq "all three nodes succeed" "$(cat "${WORK}"/node?.rc | sort -u | tr '\n' ' ')" "0 "
assert_eq "exactly one node built the PKI" "$(cat "${WORK}"/node?.log | grep -c 'PKI ready (bootstrapped)')" "1"
assert_eq "the other two restored it" "$(cat "${WORK}"/node?.log | grep -c 'PKI ready (restored)')" "2"
assert_eq "one set of CA certificates (one Root CA, not three)" "$(grep -c 'BEGIN CERTIFICATE' "${FILES}/root-ca.pem")" "1"
for n in 1 2 3; do
  assert_file "node ${n} has the Enrollment CA keystore in its own tmpfs" "${WORK}/e/tmpfs-node${n}/intermediate-ca-signing.jks"
done
assert_eq "the lock is released" "$([[ -e "${FILES}/.locks/pki-bootstrap.lock" ]] && echo held || echo free)" "free"
# a node that starts while another one is half way: ca.pem exists, the state file does not yet. It must wait for the lock,
# not take the stack for one with a PKI from the old flow.
echo "a node that sees ca.pem of a node that is still bootstrapping waits"
fresh f
mkdir -p "${FILES}/.locks"
printf 'other:1:1:1 60 othernode\n' > "${FILES}/.locks/pki-bootstrap.lock"
echo "half done" > "${FILES}/ca.pem"
( export CLUSTER_LOCK_WAIT=2 CLUSTER_LOCK_POLL=0.2; "${SCRIPT}" > "${WORK}/run.log" 2>&1; echo $? > "${WORK}/rc" )
assert_eq "it did not decide (exit 75 from the lock, not 2 for the old flow)" "$(cat "${WORK}/rc")" "75"
echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
