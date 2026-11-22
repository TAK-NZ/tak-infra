#!/bin/bash
# Tests for docker-container/scripts/rotation-coverage.sh (#171, slice C): who is still on the old side of a rotation.
#
# Same set-up as the other PKI tests (test/KmsCa/pki-harness.sh). The TAK Server API is a stub `curl` that answers the
# two calls from files; the certificates in the answers are real ones, issued by Enrollment CA 01 and a second
# Enrollment CA 02 (signed by Intermediate CA S through kms-ca.sh). The clock is PKI_ROTATION_NOW.
# Needs: openssl 3 with the libp11 "pkcs11" engine, softhsm2, opensc, jq, keytool.
# Run from the repository root:  test/KmsCa/test-rotation-coverage.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pki-harness.sh"
BOOTSTRAP="${REPO_ROOT}/docker-container/scripts/pki-bootstrap.sh"
TRUST="${REPO_ROOT}/docker-container/scripts/pki-trust.sh"
COV="${REPO_ROOT}/docker-container/scripts/rotation-coverage.sh"
export StackName=TAK-Test CLUSTER_LOCK_POLL=0.2
DAY=86400
T0=1800000000
export PKI_ROTATION_NOW="${T0}"

new_stack() { fresh "$1"; "${BOOTSTRAP}" > "${WORK}/bootstrap.log" 2>&1 || { echo "bootstrap failed"; tail -5 "${WORK}/bootstrap.log"; exit 1; }; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z; }
# a client certificate: name cn serial days-ago-issued days-valid ca (1|2)
issue() {
  local name="$1" cn="$2" serial="$3" ago="$4" valid="$5" ca="$6" capem cakey
  if [[ "${ca}" == 1 ]]; then capem="${FILES}/enrollment-ca.pem"; cakey="${WORK}/cl1.key"; else capem="${WORK}/cl2.pem"; cakey="${WORK}/cl2.key"; fi
  openssl genrsa -out "${WORK}/${name}.key" 2048 2> /dev/null
  openssl req -new -key "${WORK}/${name}.key" -subj "/O=TAK.NZ/CN=${cn}" -out "${WORK}/${name}.csr"
  # the dates of the API answer are in entry(); the certificate only has to come from the right CA
  openssl x509 -req -sha256 -in "${WORK}/${name}.csr" -CA "${capem}" -CAkey "${cakey}" -set_serial "${serial}" -extensions client -extfile "${WORK}/ext.cfg" -days "${valid}" -out "${WORK}/${name}.pem" > /dev/null 2>&1
}
# a certadmin entry as the TAK Server API returns it
entry() { # id user pemfile issued-days-ago valid-days [revoked]
  jq -n -c --argjson id "$1" --arg u "$2" --rawfile pem "$3" --arg issued "$(iso $((T0 - $4 * DAY)))" --arg exp "$(iso $((T0 - $4 * DAY + $5 * DAY)))" --arg rev "${6:-}" --arg serial "s$1" \
    '{id: $id, userDn: $u, subjectDn: ("CN=" + $u), certificate: $pem, issuanceDate: $issued, effectiveDate: $issued, expirationDate: $exp, revocationDate: (if $rev == "" then null else $rev end), serialNumber: $serial}'
}
ep() { # user callsign days-ago status
  jq -n -c --arg u "$1" --arg c "$2" --arg t "$(iso $((T0 - $3 * DAY)))" --arg s "$4" '{callsign: $c, uid: ("uid-" + $u), username: $u, lastEventTime: $t, lastStatus: $s}'
}
cat > "${WORK}/bin/curl-cov" <<'CURL'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
echo "${url}" >> "${STUB_LOG}/curl.log"
case "${url}" in
  */clientEndPoints) [[ "${STUB_COV_FAIL:-}" == endpoints ]] && exit 22; cat "${STUB_LOG}/endpoints.json" ;;
  */certadmin/cert) [[ "${STUB_COV_FAIL:-}" == certadmin ]] && exit 22; cat "${STUB_LOG}/certs.json" ;;
  *) exit 22 ;;
esac
CURL
chmod +x "${WORK}/bin/curl-cov"
export CURL_BIN="${WORK}/bin/curl-cov"
cov() { "${COV}" "$@" 2> "${WORK}/err.log"; }

echo "setup: a first-boot PKI with two Enrollment CAs"
new_stack main
printf '[ client ]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=critical,clientAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' > "${WORK}/ext.cfg"
openssl pkcs12 -in "${TMPFS}/intermediate-ca-signing.p12" -passin pass:atakatak -nodes -nocerts -out "${WORK}/cl1.key" 2> /dev/null
openssl genrsa -out "${WORK}/cl2.key" 2048 2> /dev/null
openssl req -new -key "${WORK}/cl2.key" -subj "/O=TAK.NZ/CN=TAK.NZ Try Enrollment CA 02" -out "${WORK}/cl2.csr"
"${PKI_KMS_CA_SCRIPT}" issue-ca intermediate-ca-01 "${FILES}/intermediate-ca.pem" "${WORK}/cl2.csr" "${WORK}/cl2.pem" 1000 > /dev/null || { echo "cannot sign Cl2"; exit 1; }
"${TRUST}" add enrollment-ca-02 "${WORK}/cl2.pem" server > /dev/null 2>&1
# users (see the table in the comments of each case)
issue c_conn u-conn 0x11 100 365 1          # connected, newest certificate 100 days old, Cl1
issue c_recent_old u-recent 0x12 300 365 1  # seen 3 days ago: an old Cl1 certificate ...
issue c_recent_new u-recent 0x13 20 365 2   # ... and a newer one from Cl2
issue c_oldnew u-old 0x14 200 365 1         # seen 10 days ago, only an old Cl1 certificate
issue c_mixed u-mixed 0x15 100 365 2        # newest certificate is old, but from Cl2
issue c_relogin u-relogin 0x16 10 365 1     # newest certificate is recent, but still from Cl1
issue c_inactive u-inactive 0x17 200 365 1  # not seen for 60 days
issue c_revoked u-revoked 0x18 50 365 1     # its only certificate is revoked
issue c_expired u-expired 0x19 400 365 1    # its only certificate has expired
{
  jq -n -c '{version: "3", type: "x", data: ['"$(
    { ep u-conn AWS-A 100 Connected; ep u-recent ATAK-1 40 Disconnected; ep u-recent ATAK-1 3 Disconnected; ep u-old ATAK-2 10 Disconnected; ep u-mixed ATAK-3 5 Disconnected
      ep u-relogin ATAK-4 1 Disconnected; ep u-inactive ATAK-5 60 Disconnected; ep u-revoked ATAK-6 1 Disconnected; ep u-expired ATAK-7 2 Disconnected; ep u-nocert ATAK-8 1 Disconnected; ep "" nobody 1 Connected; } | paste -sd,)"']}'
} > "${STUB_LOG}/endpoints.json"
{
  jq -n -c '{version: "3", type: "x", data: ['"$(
    { entry 1 u-conn "${WORK}/c_conn.pem" 100 365; entry 2 u-recent "${WORK}/c_recent_old.pem" 300 365; entry 3 u-recent "${WORK}/c_recent_new.pem" 20 365
      entry 4 u-old "${WORK}/c_oldnew.pem" 200 365; entry 5 u-mixed "${WORK}/c_mixed.pem" 100 365; entry 6 u-relogin "${WORK}/c_relogin.pem" 10 365
      entry 7 u-inactive "${WORK}/c_inactive.pem" 200 365; entry 8 u-revoked "${WORK}/c_revoked.pem" 50 365 "2026-12-01T00:00:00Z"
      entry 9 u-expired "${WORK}/c_expired.pem" 400 365; } | paste -sd,)"']}'
} > "${STUB_LOG}/certs.json"
BEFORE=$((T0 - 50 * DAY))

echo "--issued-before: the chain changed 50 days ago"
assert_eq "the number of stragglers: u-conn (connected, newest certificate 100 days old), u-old and u-mixed (old although from Cl2)" "$(cov --issued-before ${BEFORE})" "3"
assert_eq "exit 0 and nothing on stderr" "$?/$(wc -c < "${WORK}/err.log")" "0/0"
cov --issued-before ${BEFORE} --list > "${WORK}/list.txt"
for u in u-conn u-old u-mixed; do assert_contains "the list names ${u} as straggler" "$(grep "^straggler" "${WORK}/list.txt")" "${u} "; done
for u in u-recent u-relogin u-inactive; do assert_not_contains "the list does not name ${u}" "$(cat "${WORK}/list.txt")" "${u} "; done
assert_eq "u-revoked, u-expired and u-nocert are unknown (active, no valid certificate in the list)" "$(grep '^unknown' "${WORK}/list.txt" | awk '{print $2}' | sort | tr '\n' ' ')" "u-expired u-nocert u-revoked "
assert_contains "the header counts them" "$(head -2 "${WORK}/list.txt" | tr '\n' ' ')" "Still on the old side: 3; unknown (no certificate from TAK Server enrolment): 3"
assert_eq "the user with an empty name is ignored, and a user with two sightings counts once" "$(cov --issued-before ${BEFORE} --json | jq -r '.activeUsers')" "8"
assert_eq "--unknown-blocks counts the unknown users too" "$(cov --issued-before ${BEFORE} --unknown-blocks)" "6"
echo "--issuer enrollment-ca-01: who depends on certificates of the old Enrollment CA"
assert_eq "u-conn, u-old and u-relogin have no newer certificate from another CA" "$(cov --issuer enrollment-ca-01)" "3"
cov --issuer enrollment-ca-01 --list > "${WORK}/list.txt"
assert_eq "...those three" "$(grep '^straggler' "${WORK}/list.txt" | awk '{print $2}' | sort | tr '\n' ' ')" "u-conn u-old u-relogin "
assert_contains "the issuer is shown" "$(grep 'u-conn' "${WORK}/list.txt")" "enrollment-ca-01"
assert_eq "for Enrollment CA 02: u-mixed and u-recent (newest certificate from Cl2)" "$(cov --issuer enrollment-ca-02)" "2"
echo "the activity window"
assert_eq "--active-days 5: u-old (seen 10 days ago) is no longer active, u-conn is (connected)" "$(cov --issued-before ${BEFORE} --active-days 5)" "2"
assert_eq "--active-days 365: u-inactive counts (its certificate is from before the change)" "$(cov --issued-before ${BEFORE} --active-days 365)" "4"
assert_eq "the activity window is 30 days by default" "$(cov --issued-before ${BEFORE} --json | jq -r '.activeDays')" "30"
echo "nobody is left: the gate opens"
assert_eq "everybody has a certificate after the change: 0" "$(cov --issued-before $((T0 - 1000 * DAY)))" "0"
echo "--json"
cov --issued-before ${BEFORE} --json > "${WORK}/c.json"
assert_eq "counts and users" "$(jq -r '[.stragglers, .unknown, .counted, (.users | length), .mode] | join(",")' "${WORK}/c.json")" "3,3,3,6,before"
assert_eq "a straggler carries the dates of its newest certificate" "$(jq -r '.users[] | select(.user == "u-conn") | [.kind, .issuer, ((.issued | todate) | .[0:10])] | join(",")' "${WORK}/c.json")" "straggler,enrollment-ca-01,$(date -u -d "@$((T0 - 100 * DAY))" +%Y-%m-%d)"

echo "failures: nothing on stdout, exit 1, so that the gate stays closed"
assert_eq "clientEndPoints fails" "$(STUB_COV_FAIL=endpoints "${COV}" --issued-before ${BEFORE} 2> /dev/null; echo "[$?]")" "[1]"
assert_eq "certadmin fails" "$(STUB_COV_FAIL=certadmin "${COV}" --issued-before ${BEFORE} 2> /dev/null; echo "[$?]")" "[1]"
assert_eq "no mode: exit 1" "$("${COV}" 2> /dev/null; echo "[$?]")" "[1]"
assert_eq "an invalid alias: exit 1" "$("${COV}" --issuer root-ca-01 2> /dev/null; echo "[$?]")" "[1]"
assert_eq "an unknown option: exit 1" "$("${COV}" --issued-before ${BEFORE} --bogus 2> /dev/null; echo "[$?]")" "[1]"
echo '<html>not json</html>' > "${STUB_LOG}/certs.json.bad"
cp "${STUB_LOG}/certs.json" "${STUB_LOG}/certs.json.good"; cp "${STUB_LOG}/certs.json.bad" "${STUB_LOG}/certs.json"
assert_eq "an answer that is not a list: exit 1" "$("${COV}" --issued-before ${BEFORE} 2> /dev/null; echo "[$?]")" "[1]"
cp "${STUB_LOG}/certs.json.good" "${STUB_LOG}/certs.json"
echo "the API is called with the admin certificate, and only these two calls"
: > "${STUB_LOG}/curl.log"
cov --issued-before ${BEFORE} > /dev/null
assert_eq "two calls" "$(sed 's#.*/Marti/api##' "${STUB_LOG}/curl.log" | sort | tr '\n' ' ')" "/certadmin/cert /clientEndPoints "

echo
echo "passed: ${PASS}, failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
