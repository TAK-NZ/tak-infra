#!/bin/bash
# rotation-coverage.sh - the coverage check of the rotation orchestrator (#171, slice C).
#
#   rotation-coverage.sh --issued-before EPOCH [options]     phones that have not got a certificate since EPOCH
#   rotation-coverage.sh --issuer enrollment-ca-NN [options] users whose newest certificate is from that Enrollment CA
#   options: --active-days N (default PKI_COVERAGE_ACTIVE_DAYS or 30)   --list   --json   --unknown-blocks
#
# Why. A rotation that changes what phones must trust (the Intermediate CA bridge, #172; the Root CA, #169) may
# remove the old trust only when every active user has enrolled again under the new chain. The removal of an old
# Enrollment CA (#135) must wait until no active user depends on a certificate that it issued. Time (the window W)
# is the usual proof; this check is the other half: it asks TAK Server who is still on the old side.
#
# How. Two calls of the TAK Server API with the admin certificate:
#   /Marti/api/clientEndPoints      who connected, and when (`username`, `lastEventTime`, `lastStatus`)
#   /Marti/api/certadmin/cert       every certificate that TAK Server issued through enrolment (`userDn`,
#                                   issuance and expiry dates, revocation, the certificate itself)
# An *active* user is connected now or was seen in the last N days. Its *newest valid certificate* is the one with
# the latest issuance date that is not revoked and not expired. The user is a *straggler* when
#   --issued-before EPOCH   that certificate was issued before EPOCH (the chain changed at EPOCH), or
#   --issuer ALIAS          that certificate was issued by the Enrollment CA ALIAS (a newer CA has not issued one).
# An active user without any valid certificate in the list is *unknown*: it connects with a certificate that TAK
# Server did not issue through enrolment (a data package made by hand), so nothing can be said about its chain. Unknown
# users are reported but do not count, unless --unknown-blocks is given.
#
# Output. Default: one number, the stragglers, on stdout; exit 0. On any failure (the API does not answer, a call
# is refused) it prints nothing on stdout and exits 1: the orchestrator then keeps the gate closed.
# --list: a table of stragglers and unknown users. --json: the same as JSON (counts and users).
#
# Environment: COVERAGE_API_BASE (https://localhost:8443/Marti/api), CURL_BIN (curl), PKI_ROTATION_NOW (epoch).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_BOOTSTRAP_SOURCE_ONLY=1
# shellcheck source=pki-bootstrap.sh
source "${SCRIPT_DIR}/pki-bootstrap.sh"
API="${COVERAGE_API_BASE:-https://localhost:8443/Marti/api}"
CURL="${CURL_BIN:-curl}"
now() { echo "${PKI_ROTATION_NOW:-$(date +%s)}"; }
fail() { echo "rotation-coverage: $*" >&2; exit 1; }
api() { # path -> JSON on stdout
  "${CURL}" -sk -f --max-time 30 --cert "${FILES_DIR}/admin.pem" --key "${FILES_DIR}/admin.key" --pass "${KS_PASS}" "${API}$1"
}

main() {
  local mode="" value="" days="${PKI_COVERAGE_ACTIVE_DAYS:-30}" out="count" unknown_blocks=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issued-before) mode="before"; value="${2:-}"; shift ;;
      --issuer) mode="issuer"; value="${2:-}"; shift ;;
      --active-days) days="${2:-}"; shift ;;
      --list) out="list" ;;
      --json) out="json" ;;
      --unknown-blocks) unknown_blocks=1 ;;
      *) fail "unknown argument '$1'" ;;
    esac
    shift
  done
  [[ "${mode}" == before && "${value}" =~ ^[0-9]+$ ]] || [[ "${mode}" == issuer && "${value}" =~ ^enrollment-ca-[0-9]{2}$ ]] \
    || fail "give --issued-before EPOCH or --issuer enrollment-ca-NN"
  [[ "${days}" =~ ^[0-9]+$ ]] || fail "--active-days must be a number"
  [[ -f "${STATE_FILE}" ]] || fail "no first-boot PKI on this stack"
  local endpoints certs
  endpoints="$(api /clientEndPoints)" || fail "the clientEndPoints call failed"
  certs="$(api /certadmin/cert)" || fail "the certadmin call failed"
  jq -e '.data | type == "array"' <<< "${endpoints}" > /dev/null 2>&1 || fail "the clientEndPoints answer is not a list"
  jq -e '.data | type == "array"' <<< "${certs}" > /dev/null 2>&1 || fail "the certadmin answer is not a list"

  # the issuer of every certificate as a name, mapped to the alias of an Enrollment CA of the trust manifest
  local aliases_json="{}" a ca subj
  while IFS= read -r a; do
    ca="$(crl_ca_cert "${a}")"
    [[ -s "${ca}" ]] || continue
    subj="$(openssl x509 -in "${ca}" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
    aliases_json="$(jq -c --arg s "${subj}" --arg a "${a}" '.[$s] = $a' <<< "${aliases_json}")"
  done < <(crl_aliases)
  local valid="[]" t pem issuer alias row
  t="$(now)"
  # only the certificates that count: not revoked, not expired
  while IFS=$'\t' read -r user issued expires serial b64; do
    pem="$(base64 -d <<< "${b64}")"
    issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 <<< "${pem}" 2> /dev/null | sed 's/^issuer=//')"
    alias="$(jq -r --arg i "${issuer}" '.[$i] // "unknown"' <<< "${aliases_json}")"
    row="$(jq -n -c --arg u "${user}" --argjson i "${issued}" --argjson e "${expires}" --arg s "${serial}" --arg a "${alias}" '{user: $u, issued: $i, expires: $e, serial: $s, issuer: $a}')"
    valid="$(jq -c ". + [${row}]" <<< "${valid}")"
  done < <(jq -r --argjson now "${t}" '
      def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      .data[] | select(.revocationDate == null and (.userDn // "") != "" and (.expirationDate | epoch) > $now and (.issuanceDate | epoch) <= $now)
      | [.userDn, (.issuanceDate | epoch), (.expirationDate | epoch), .serialNumber, (.certificate | @base64)] | @tsv' <<< "${certs}")

  local result
  result="$(jq -n -c --argjson ep "${endpoints}" --argjson valid "${valid}" --argjson now "${t}" --argjson days "${days}" \
    --arg mode "${mode}" --arg value "${value}" --argjson ub "${unknown_blocks}" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    # active users: connected now, or seen within the window; the newest sighting per user
    ($ep.data | map(select((.username // "") != "")
        | {user: .username, callsign: (.callsign // ""), seen: (.lastEventTime | epoch), connected: (.lastStatus == "Connected")}
        | select(.connected or .seen >= ($now - $days * 86400)))
      | group_by(.user) | map(max_by(.seen))) as $active
    | ($valid | group_by(.user) | map({key: .[0].user, value: max_by(.issued)}) | from_entries) as $newest
    | ($active | map(. as $u | ($newest[$u.user]) as $c
        | if $c == null then {user: $u.user, callsign: $u.callsign, seen: $u.seen, kind: "unknown"}
          elif ($mode == "before" and $c.issued < ($value | tonumber)) or ($mode == "issuer" and $c.issuer == $value)
            then {user: $u.user, callsign: $u.callsign, seen: $u.seen, kind: "straggler", issued: $c.issued, expires: $c.expires, issuer: $c.issuer}
          else empty end)) as $rows
    | {now: $now, activeDays: $days, mode: $mode, value: $value, activeUsers: ($active | length),
       stragglers: ($rows | map(select(.kind == "straggler")) | length),
       unknown: ($rows | map(select(.kind == "unknown")) | length),
       counted: (($rows | map(select(.kind == "straggler")) | length) + (if $ub == 1 then ($rows | map(select(.kind == "unknown")) | length) else 0 end)),
       users: ($rows | sort_by(.user))}')" || fail "could not evaluate the answers of TAK Server"
  case "${out}" in
    count) jq -r '.counted' <<< "${result}" ;;
    json) jq . <<< "${result}" ;;
    list)
      jq -r '"Active users (connected now or seen in the last \(.activeDays) days): \(.activeUsers)\nStill on the old side: \(.stragglers); unknown (no certificate from TAK Server enrolment): \(.unknown)"' <<< "${result}"
      jq -r '.users[] | [.kind, .user, .callsign, (.seen | todate | .[0:10]), (if .issued then (.issued | todate | .[0:10]) else "-" end), (if .expires then (.expires | todate | .[0:10]) else "-" end), (.issuer // "-")] | @tsv' <<< "${result}" \
        | awk -F'\t' 'BEGIN {printf "%-10s %-24s %-18s %-11s %-11s %-11s %s\n", "kind", "user", "callsign", "last seen", "cert from", "cert until", "issuer"} {printf "%-10s %-24s %-18s %-11s %-11s %-11s %s\n", $1, $2, $3, $4, $5, $6, $7}'
      ;;
  esac
}
main "$@"
