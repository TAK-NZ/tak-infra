#!/bin/bash
# rotation/intermediate.sh - the rotation of the Intermediate CA (S) in two phases, bridge and cut (#172, scenario of
# pki-rotate.sh, #171). Sourced by pki-rotate.sh together with rotation/enrollment.sh, whose functions it uses.
#
# Why two phases. ATAK ignores the chain that the server sends (#170): the issuer of the server certificate must already be
# in the truststore of every phone. A phone holds {S_old, R} or, after an enrolment during the bridge, {A, S_old, R}.
#   A  the certificate for the S_new key, issued by S_old (pathlen 1)
#   B  the certificate for the same key and subject, issued by R (pathlen 2)
# The bridge makes new enrolments carry A, so that a phone has S_new's issuer before anything is signed by S_new alone. The
# cut then signs the server certificate with S_new and gives new enrolments {B, R}.
#
#   create   S_old issues A. A new Enrollment CA (Cl_new) is signed by S_new, with the chain [A, S_old, R]. Stored,
#            trusted by the manifest, empty CRL. Nothing in use changes.
#   bridge   Truststores: S_old, A, R and both Cl. Cl_new becomes the signing keystore, chain [Cl_new, A, S_old, R]. The
#            server certificate stays signed by S_old. Restart.
#   admin    (gate restart) the admin certificate is signed by Cl_new. The time is recorded: from then on a new enrolment
#            carries the chain through A (bridgeAt).
#   cut      (gates window, coverage --issued-before bridgeAt, approval) R issues B (a Root CA signature: RootCASigned
#            fires). B goes into the manifest, becomes intermediate-ca.pem, S_new becomes the current Intermediate CA; the
#            server certificate and the admin certificate are re-issued, the keystore of Cl_new gets the chain [B, R].
#            Phones with {S_old, R} only are cut off, which is what the coverage check is for. Restart.
#   retire   (gates window, coverage --issued-before cutAt, approval) S_old, A and Cl_old leave the truststores, the CRL of
#            Cl_old is deleted, its key is destroyed. The KMS key of S_old is deleted by an operator (the log says how).
#
# Starts when S has 2 x W + 365 days or fewer left, the manifest lists one Enrollment CA, and the next key generation of S
# exists in PKI_KMS_CA_KEYS. Abort works before the bridge (it undoes `create`); after it the rotation can only go on.
# Data of the rotation in rotation-state.json `.active.data`: old, new (S numbers), clOld, clNew, bridgeAt, cutAt, flags.

intermediate_alias() { printf 'intermediate-ca-%02d' "$1"; }
intermediate_bridge_alias() { printf 'intermediate-ca-%02d-bridge' "$1"; }
intermediate_file() { echo "trust-certs/$1.pem"; } # relative to the files directory
intermediate_data() { st_get ".active.data.$1 // empty"; }
intermediate_label() { printf 'intermediate-ca-%02d' "$1"; }

# the next key generation of S: the smallest number above the current one that PKI_KMS_CA_KEYS has
intermediate_next_number() {
  local cur slot n best=""
  cur="$(jq -r '.numbers.intermediate' "${STATE_FILE}")"
  while IFS= read -r slot; do
    [[ "${slot}" =~ ^intermediate-ca-([0-9]{2})= ]] || continue
    n=$(( 10#${BASH_REMATCH[1]} ))
    (( n > cur )) && { [[ -z "${best}" ]] || (( n < best )); } && best="${n}"
  done < <(tr ',' '\n' <<< "${PKI_KMS_CA_KEYS:-}")
  echo "${best}"
}

intermediate_summary() {
  local pem="${FILES_DIR}/intermediate-ca.pem" e
  e="$(cert_enddate "${pem}")"
  echo "$(jq -r .names.intermediate "${STATE_FILE}")|${e}|$(( e - (2 * WINDOW_DAYS + 365) * DAY ))|expiry - (2 x W + 365 days)"
}

intermediate_due() {
  local pem="${FILES_DIR}/intermediate-ca.pem" t left n next
  [[ -s "${pem}" ]] || return 1
  t="$(now)"
  left=$(( ($(cert_enddate "${pem}") - t) / DAY ))
  (( left <= 2 * WINDOW_DAYS + 365 )) || return 1
  trust_ensure_manifest || return 1
  n="$(crl_aliases | grep -c .)" || true
  if (( n != 1 )); then
    log "intermediate: the Intermediate CA has ${left} days left, but the manifest lists ${n} Enrollment CAs: no rotation until there is one"
    return 1
  fi
  next="$(intermediate_next_number)"
  if [[ -z "${next}" ]]; then
    log "WARNING: the Intermediate CA has ${left} days left and its rotation is due, but PKI_KMS_CA_KEYS has no later generation: add the next number to pki.kmsCa.intermediateCaNumbers and deploy (a CDK deploy creates the key)"
    return 1
  fi
  # A is valid for what S_old has left, and the new Enrollment CA under it needs its rotation period plus W
  if (( left - 1 < CL_ROTATION_DAYS + WINDOW_DAYS )); then
    log "WARNING: the Intermediate CA has ${left} days left: too little for a rotation (a new Enrollment CA needs $(( CL_ROTATION_DAYS + WINDOW_DAYS )) days under it). Set PKI_ENROLLMENT_CA_ROTATION_DAYS lower or replace the Intermediate CA by hand"
    return 1
  fi
  return 0
}

intermediate_steps() { echo "create bridge admin cut retire"; }
intermediate_gate() {
  case "$1" in
    create | bridge) echo none ;;
    admin) echo restart ;;
    cut | retire) echo "window coverage" ;;
  esac
}
# cut: phones that took the bridge chain need W after the cut to enrol under B before S_old expires. retire: 30 days
# before it expires.
intermediate_deadline() {
  local old pem
  old="$(intermediate_data old)"
  [[ -n "${old}" ]] || return 0
  pem="${FILES_DIR}/$(intermediate_file "$(intermediate_alias "${old}")")"
  [[ -s "${pem}" ]] || pem="${FILES_DIR}/intermediate-ca.pem"
  case "$1" in
    cut) echo $(( $(cert_enddate "${pem}") - (WINDOW_DAYS + 90) * DAY )) ;;
    retire) echo $(( $(cert_enddate "${pem}") - 30 * DAY )) ;;
  esac
}
intermediate_coverage_args() {
  case "$1" in
    cut) echo "--issued-before $(intermediate_data bridgeAt)" ;;
    retire) echo "--issued-before $(intermediate_data cutAt)" ;;
  esac
}

# --- create ----------------------------------------------------------------------------------
intermediate_create_in() { # workdir
  local w="$1" old new cl a_alias a_file days left
  old="$(intermediate_data old)"; new="$(intermediate_data new)"; cl="$(intermediate_data clNew)"
  a_alias="$(intermediate_bridge_alias "${new}")"
  a_file="$(intermediate_file "${a_alias}")"
  # A: S_old signs the certificate for the S_new key (pathlen 1: it issues the Enrollment CA). An earlier run may have
  # done it and been interrupted: the file is kept if it is for this key and chains to R
  "${KMS_CA}" csr "$(intermediate_label "${new}")" "${w}/s-new.csr" > /dev/null || { log "ERROR: no CSR for $(intermediate_label "${new}") (is the key in PKI_KMS_CA_KEYS?)"; return 1; }
  if [[ -s "${FILES_DIR}/${a_file}" ]] \
     && [[ "$(openssl x509 -in "${FILES_DIR}/${a_file}" -noout -pubkey | openssl sha256)" == "$(openssl req -in "${w}/s-new.csr" -noout -pubkey | openssl sha256)" ]] \
     && openssl verify -CAfile "${FILES_DIR}/root-ca.pem" -untrusted "${FILES_DIR}/intermediate-ca.pem" "${FILES_DIR}/${a_file}" > /dev/null 2>&1; then
    log "intermediate: the certificate ${a_alias} exists already: continuing with it"
  else
    left=$(( ($(cert_enddate "${FILES_DIR}/intermediate-ca.pem") - $(now)) / DAY ))
    days="${INTERMEDIATE_DAYS}"
    (( left - 1 < days )) && days=$(( left - 1 ))
    log "intermediate: the certificate for $(intermediate_label "${new}") from $(intermediate_label "${old}"), ${days} days, pathlen 1"
    "${KMS_CA}" issue-ca "$(intermediate_label "${old}")" "${FILES_DIR}/intermediate-ca.pem" "${w}/s-new.csr" "${w}/a.pem" "${days}" 1 > /dev/null \
      || { log "ERROR: $(intermediate_label "${old}") could not issue the bridge certificate"; return 1; }
    openssl verify -CAfile "${FILES_DIR}/root-ca.pem" -untrusted "${FILES_DIR}/intermediate-ca.pem" "${w}/a.pem" > /dev/null 2>&1 \
      || { log "ERROR: the bridge certificate does not chain to the Root CA"; return 1; }
    [[ "$(openssl x509 -in "${w}/a.pem" -noout -ext basicConstraints 2> /dev/null)" == *"pathlen:1"* ]] || { log "ERROR: the bridge certificate has not got pathlen 1"; return 1; }
    mkdir -p "${FILES_DIR}/trust-certs"
    cp "${w}/a.pem" "${FILES_DIR}/${a_file}.new" && chmod 644 "${FILES_DIR}/${a_file}.new" && mv -f "${FILES_DIR}/${a_file}.new" "${FILES_DIR}/${a_file}" || return 1
  fi
  trust_add "${a_alias}" "${FILES_DIR}/${a_file}" server,phone,fed || return 1
  # Cl_new under S_new: chain [A, S_old, R]
  cat "${FILES_DIR}/${a_file}" "${FILES_DIR}/intermediate-ca.pem" "${FILES_DIR}/root-ca.pem" > "${w}/chain-bridge.pem" || return 1
  ENROLLMENT_ISSUER_LABEL="$(intermediate_label "${new}")" ENROLLMENT_ISSUER_PEM="${FILES_DIR}/${a_file}" ENROLLMENT_CHAIN="${w}/chain-bridge.pem" \
    enrollment_create_in "${w}" "${cl}" || return 1
  log "intermediate: ${a_alias} and $(enrollment_alias "${cl}") are stored and in the manifest; the bridge makes TAK Server use them"
}
intermediate_create() {
  local old new cl w rc
  old="$(jq -r '.numbers.intermediate' "${STATE_FILE}")"
  new="$(intermediate_data new)"
  if [[ -z "${new}" ]]; then
    new="$(intermediate_next_number)"
    [[ -n "${new}" ]] || { log "ERROR: PKI_KMS_CA_KEYS has no later Intermediate CA generation"; return 1; }
    cl="$(enrollment_new_number)"
    (( cl <= 99 )) || { log "ERROR: Enrollment CA numbers go up to 99"; return 1; }
    st_set --argjson o "${old}" --argjson n "${new}" --argjson co "$(jq -r '.numbers.enrollment' "${STATE_FILE}")" --argjson cn "${cl}" \
      '.active.data = {old: $o, new: $n, clOld: $co, clNew: $cn}' || return 1
  fi
  mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
  w="$(umask 077; mktemp -d "${TMPFS_DIR}/intermediate.XXXXXX")" || return 1
  rc=0
  intermediate_create_in "${w}" || rc=$?
  find "${w}" -delete 2> /dev/null
  return "${rc}"
}

# --- bridge ----------------------------------------------------------------------------------
intermediate_bridge() {
  local new cl_old cl_new w rc=0
  new="$(intermediate_data new)"; cl_old="$(intermediate_data clOld)"; cl_new="$(intermediate_data clNew)"
  [[ -n "${new}" && -n "${cl_old}" && -n "${cl_new}" ]] || { log "ERROR: the rotation has no numbers"; return 1; }
  mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
  w="$(umask 077; mktemp -d "${TMPFS_DIR}/intermediate.XXXXXX")" || return 1
  cat "${FILES_DIR}/$(intermediate_file "$(intermediate_bridge_alias "${new}")")" "${FILES_DIR}/intermediate-ca.pem" "${FILES_DIR}/root-ca.pem" > "${w}/chain-bridge.pem" || { find "${w}" -delete; return 1; }
  ENROLLMENT_NEW_CHAIN="${w}/chain-bridge.pem" enrollment_activate "${cl_old}" "${cl_new}" || rc=$?
  find "${w}" -delete 2> /dev/null
  (( rc == 10 )) || return "${rc}"
  "${METRICS}" emit IntermediateCARotationPhase 1 Phase=bridge || true
  log "intermediate: the bridge is in place: new enrolments carry the chain through $(intermediate_bridge_alias "${new}")"
  return 10
}

# --- admin -----------------------------------------------------------------------------------
intermediate_admin() {
  enrollment_admin_for "$(intermediate_data clNew)" || return $?
  # from here on, an enrolment carries the bridge chain: the old task has been replaced (gate restart)
  [[ -n "$(intermediate_data bridgeAt)" ]] || st_set --argjson t "$(now)" '.active.data.bridgeAt = $t' || return 1
  log "intermediate: new enrolments carry the bridge chain since $(fmt_date "$(intermediate_data bridgeAt)"); phones that enrolled before are the stragglers of the cut"
}

# --- cut -------------------------------------------------------------------------------------
# an atomic copy into the files directory
intermediate_install() { # src dest(relative)
  mkdir -p "$(dirname "${FILES_DIR}/$2")"
  cp "$1" "${FILES_DIR}/$2.new" && chmod 644 "${FILES_DIR}/$2.new" && mv -f "${FILES_DIR}/$2.new" "${FILES_DIR}/$2"
}
intermediate_cut_in() { # workdir
  local w="$1" old new cl s_alias a_alias b_file s_file days rleft root_n rc
  old="$(intermediate_data old)"; new="$(intermediate_data new)"; cl="$(intermediate_data clNew)"
  s_alias="$(intermediate_alias "${new}")"; a_alias="$(intermediate_bridge_alias "${new}")"
  b_file="$(intermediate_file "${s_alias}")"
  s_file="$(intermediate_file "$(intermediate_alias "${old}")")"
  # 1. B: the Root CA issues the certificate for the S_new key (the same key and subject as A)
  if [[ ! -s "${FILES_DIR}/${b_file}" ]]; then
    root_n="$(jq -r '.numbers.root' "${STATE_FILE}")"
    "${KMS_CA}" csr "$(intermediate_label "${new}")" "${w}/s-new.csr" > /dev/null || { log "ERROR: no CSR for $(intermediate_label "${new}")"; return 1; }
    rleft=$(( ($(cert_enddate "${FILES_DIR}/root-ca.pem") - $(now)) / DAY ))
    days="${INTERMEDIATE_DAYS}"
    (( rleft - 1 < days )) && days=$(( rleft - 1 ))
    log "intermediate: the Root CA issues the certificate B for $(intermediate_label "${new}"), ${days} days (a Root CA signature)"
    "${KMS_CA}" issue-ca "$(printf 'root-ca-%02d' "${root_n}")" "${FILES_DIR}/root-ca.pem" "${w}/s-new.csr" "${w}/b.pem" "${days}" > /dev/null \
      || { log "ERROR: the Root CA could not issue B"; return 1; }
    local a="${FILES_DIR}/$(intermediate_file "${a_alias}")"
    [[ "$(openssl x509 -in "${w}/b.pem" -noout -pubkey | openssl sha256)" == "$(openssl x509 -in "${a}" -noout -pubkey | openssl sha256)" ]] \
      || { log "ERROR: B is not for the key of A"; return 1; }
    [[ "$(openssl x509 -in "${w}/b.pem" -noout -subject)" == "$(openssl x509 -in "${a}" -noout -subject)" ]] || { log "ERROR: B has not the subject of A"; return 1; }
    openssl verify -CAfile "${FILES_DIR}/root-ca.pem" "${w}/b.pem" > /dev/null 2>&1 || { log "ERROR: B does not chain to the Root CA"; return 1; }
    [[ "$(openssl x509 -in "${w}/b.pem" -noout -ext basicConstraints 2> /dev/null)" == *"pathlen:2"* ]] || { log "ERROR: B has not got pathlen 2"; return 1; }
    intermediate_install "${w}/b.pem" "${b_file}" || return 1
  fi
  # 2. the manifest: B for everyone; S_old keeps a file of its own, because intermediate-ca.pem changes
  trust_add "${s_alias}" "${FILES_DIR}/${b_file}" server,phone,fed || return 1
  if [[ ! -s "${FILES_DIR}/${s_file}" ]]; then
    [[ "$(jq -r '.numbers.intermediate' "${STATE_FILE}")" == "${old}" ]] || { log "ERROR: ${FILES_DIR}/${s_file} is missing and S_old is not current"; return 1; }
    intermediate_install "${FILES_DIR}/intermediate-ca.pem" "${s_file}" || return 1
  fi
  trust_set_file "$(intermediate_alias "${old}")" "${s_file}" || return 1
  rc=0; trust_apply || rc=$?
  (( rc == 0 || rc == 10 )) || { log "ERROR: the truststores could not be changed"; return 1; }
  # 3. S_new is the Intermediate CA from here on: what signs the server certificate, and the FederateCA certificate
  intermediate_install "${FILES_DIR}/${b_file}" intermediate-ca.pem || return 1
  intermediate_install "${FILES_DIR}/${b_file}" ca.pem || return 1
  trust_state_set --argjson n "${new}" --arg cn "$("${KMS_CA}" common-name "$(intermediate_label "${new}")")" \
    --arg endate "$(openssl x509 -in "${FILES_DIR}/intermediate-ca.pem" -noout -enddate | cut -d= -f2)" \
    '.numbers.intermediate = $n | .names.intermediate = $cn | .notAfter.intermediate = $endate' || return 1
  # 4. the chain above Cl_new is [B, R]: new keystore (same key and certificate) in the secret and in tmpfs
  cat "${FILES_DIR}/${b_file}" "${FILES_DIR}/root-ca.pem" > "${w}/chain-cut.pem" || return 1
  if [[ "$(jq -r '.numbers.enrollment' "${STATE_FILE}")" != "${cl}" ]]; then log "ERROR: Enrollment CA ${cl} is not the current one"; return 1; fi
  openssl pkcs12 -in "${TMPFS_DIR}/intermediate-ca-signing.p12" -passin "pass:${KS_PASS}" -nodes -nocerts -out "${w}/cl.key" 2> /dev/null || { log "ERROR: cannot read the signing key"; return 1; }
  signing_keystore_build "${FILES_DIR}/enrollment-ca.pem" "${w}/cl.key" "${w}/chain-cut.pem" "${w}/cl-cut.p12" || { log "ERROR: could not build the keystore"; return 1; }
  signing_rechain "${cl}" "${w}/cl-cut.p12" || return 1
  intermediate_install "${w}/chain-cut.pem" enrollment-chain.pem || return 1
  # 5. the server certificate from S_new (no restart of its own: the orchestrator starts one) and the admin certificate
  if [[ "$(intermediate_data cutLeaf)" != "true" ]]; then
    if ! openssl verify -no_check_time -partial_chain -CAfile "${FILES_DIR}/${b_file}" "${FILES_DIR}/takserver.pem" > /dev/null 2>&1; then
      PKI_ROTATE_NO_DEPLOY=1 "${PKI_ROTATE_SERVER_SCRIPT:-${SCRIPT_DIR}/server-cert-rotate.sh}" rotate || { log "ERROR: the server certificate could not be re-issued"; return 1; }
    fi
    st_set '.active.data.cutLeaf = true' || return 1
  fi
  if [[ "$(intermediate_data cutAdmin)" != "true" ]]; then
    "${PKI_ROTATE_ADMIN_SCRIPT:-${SCRIPT_DIR}/admin-cert-rotate.sh}" rotate || { log "ERROR: the admin certificate could not be re-issued"; return 1; }
    st_set '.active.data.cutAdmin = true' || return 1
  fi
}
intermediate_cut() {
  local w rc=0
  mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
  w="$(umask 077; mktemp -d "${TMPFS_DIR}/intermediate.XXXXXX")" || return 1
  intermediate_cut_in "${w}" || rc=$?
  find "${w}" -delete 2> /dev/null
  (( rc == 0 )) || return "${rc}"
  [[ -n "$(intermediate_data cutAt)" ]] || st_set --argjson t "$(now)" '.active.data.cutAt = $t' || return 1
  "${METRICS}" emit IntermediateCARotationPhase 1 Phase=cut || true
  log "intermediate: the cut is done: $(jq -r .names.intermediate "${STATE_FILE}") signs the server certificate, new enrolments carry [Enrollment CA, B, R]"
  return 10
}

# --- retire ----------------------------------------------------------------------------------
intermediate_retire() {
  local old new rc=0 f
  old="$(intermediate_data old)"; new="$(intermediate_data new)"
  [[ -n "${old}" && -n "${new}" ]] || { log "ERROR: the rotation has no numbers"; return 1; }
  [[ "$(jq -r '.numbers.intermediate' "${STATE_FILE}")" == "${new}" ]] || { log "ERROR: $(intermediate_alias "${new}") is not the current Intermediate CA"; return 1; }
  for f in "$(intermediate_alias "${old}")" "$(intermediate_bridge_alias "${new}")"; do
    if [[ "$(jq -r --arg a "${f}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]]; then trust_remove "${f}" || return 1; fi
  done
  # Cl_old: one truststore change for all of it
  enrollment_retire_cl "$(intermediate_data clOld)" || rc=$?
  (( rc == 10 )) || return "${rc}"
  for f in "$(intermediate_alias "${old}")" "$(intermediate_bridge_alias "${new}")"; do find "${FILES_DIR}/$(intermediate_file "${f}")" -delete 2> /dev/null; done
  "${METRICS}" emit IntermediateCARotationPhase 1 Phase=retire || true
  log "intermediate: $(intermediate_alias "${old}") is retired. Its KMS key is still there and the signer role can use it: remove generation ${old} from pki.kmsCa.intermediateCaNumbers (a CDK deploy drops it from the role policy; the key is retained), then schedule its deletion in KMS with a 30-day window"
  return 10
}

intermediate_run() {
  case "$1" in
    create) intermediate_create ;;
    bridge) intermediate_bridge ;;
    admin) intermediate_admin ;;
    cut) intermediate_cut ;;
    retire) intermediate_retire ;;
    *) log "intermediate: unknown step '$1'"; return 1 ;;
  esac
}

# Before the bridge everything that `create` made is removed (the S_new key in KMS is not touched). After it the new
# Enrollment CA signs, phones hold certificates from it, and the rotation can only go on: the bridge state is stable
# (old and new phones both work, the server certificate is still S_old's).
intermediate_abort() {
  local new cl a_alias rc=0
  new="$(intermediate_data new)"; cl="$(intermediate_data clNew)"
  [[ -n "${new}" && -n "${cl}" ]] || return 0
  a_alias="$(intermediate_bridge_alias "${new}")"
  if [[ "$(jq -r '.numbers.enrollment' "${STATE_FILE}")" == "${cl}" ]]; then
    log "intermediate: $(enrollment_alias "${cl}") signs already (the bridge is in place): this rotation can only go on. It waits at its next gate, nothing is lost"
    return 2
  fi
  # A leaves the manifest first, so that the one truststore change of the undo is the final one
  if [[ "$(jq -r --arg a "${a_alias}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]]; then
    trust_remove "${a_alias}" || return 1
  fi
  enrollment_undo_create "${cl}" || rc=$?
  (( rc == 0 )) || return "${rc}"
  find "${FILES_DIR}/$(intermediate_file "${a_alias}")" -delete 2> /dev/null
  log "intermediate: the preparation of $(intermediate_label "${new}") is undone (its key in KMS is untouched)"
  return 0
}
