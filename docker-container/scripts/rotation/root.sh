#!/bin/bash
# rotation/root.sh - the rotation of the Root CA (R) with a cross-certificate of the Intermediate CA (#169, scenario of
# pki-rotate.sh, #171). Sourced by pki-rotate.sh together with the other scenarios.
#
#   R_old, R_new   Root CA keys in KMS (the next generation of PKI_KMS_CA_KEYS). R_new is self-signed.
#   B              the certificate for the Intermediate CA key S issued by R_old (what intermediate-ca.pem is)
#   C              the cross-certificate: a second certificate for the same key and subject, issued by R_new (pathlen 2)
#
# Why it is small. ATAK validates the server certificate against its own stored certificates and ignores the chain that the
# server sends (#170); the server certificate is signed by the S key, which does not change. A phone that holds {B, R_old}
# and a phone that holds {C, R_new} both accept it. So the server certificate stays as it is until the end, and the only
# thing that has to reach the phones is R_new, which enrolment delivers (the chain of the signing keystore).
#
#   create   R_new self-signed in KMS; R_new issues C. Checked, stored as files, put into the manifest. Nothing in use changes.
#   switch   Truststores get R_new and C. The signing keystore of the current Enrollment CA gets the chain [Cl, C, R_new]:
#            a new enrolment carries the new root. `ca.pem` (the FederateCA secret) becomes C. SNS tells the operator the
#            fingerprints to give to federation peers. Restart. Point of no return.
#   admin    (gate restart) the admin certificate carries the new chain. The time is recorded (newChainAt).
#   retire   (gates window, coverage --issued-before newChainAt, approval) R_new is the Root CA and C the Intermediate CA
#            certificate (root-ca.pem, intermediate-ca.pem); R_old and B leave the manifest; the server certificate is
#            re-issued so that it presents [L, C, R_new], and so is the admin certificate. Restart. The KMS key of R_old is
#            deleted by an operator (the log says how).
#
# C is not capped by B: it is valid for min(PKI_INTERMEDIATE_DAYS, what R_new has left). The cross-certificate renews the
# certificate of S, and with it the clock of the Intermediate CA rotation (#172 cannot run near the end of R_old's life,
# because its new certificate cannot outlive the root). The Intermediate CA rotation waits while the root has 3 x W + 455
# days or fewer; the root rotation starts earlier than its own trigger when S is due then.
# Data of the rotation in rotation-state.json `.active.data`: old, new (R numbers), sNum, switchStarted, newChainAt, flags.

root_alias() { printf 'root-ca-%02d' "$1"; }
root_label() { printf 'root-ca-%02d' "$1"; }
root_cross_alias() { printf 'intermediate-ca-%02d-cross' "$1"; }
root_file() { echo "trust-certs/$1.pem"; } # relative to the files directory
root_data() { st_get ".active.data.$1 // empty"; }

# the next root generation: the smallest number above the current one that PKI_KMS_CA_KEYS has
root_next_number() {
  local cur slot n best=""
  cur="$(jq -r '.numbers.root' "${STATE_FILE}")"
  while IFS= read -r slot; do
    [[ "${slot}" =~ ^root-ca-([0-9]{2})= ]] || continue
    n=$(( 10#${BASH_REMATCH[1]} ))
    (( n > cur )) && { [[ -z "${best}" ]] || (( n < best )); } && best="${n}"
  done < <(tr ',' '\n' <<< "${PKI_KMS_CA_KEYS:-}")
  echo "${best}"
}

root_summary() {
  local e
  e="$(cert_enddate "${FILES_DIR}/root-ca.pem")"
  echo "$(jq -r .names.root "${STATE_FILE}")|${e}|$(( e - (WINDOW_DAYS + 365) * DAY ))|expiry - (W + 365 days), or earlier when the Intermediate CA is due"
}

# What a rotation needs to start, whatever the trigger (`pki-rotate.sh start` checks only this)
root_preflight() {
  local n next s_left
  trust_ensure_manifest || return 1
  n="$(crl_aliases | grep -c .)" || true
  if (( n != 1 )); then
    log "root: the manifest lists ${n} Enrollment CAs: no rotation until there is one"
    return 1
  fi
  next="$(root_next_number)"
  if [[ -z "${next}" ]]; then
    log "WARNING: the Root CA rotation cannot start: PKI_KMS_CA_KEYS has no later Root CA generation: add the next number to pki.kmsCa.rootCaNumbers and deploy (a CDK deploy creates the key)"
    return 1
  fi
  # S has to outlive the rotation: the phones need W to enrol, and C renews only what is left of the clock afterwards
  s_left=$(( ($(cert_enddate "${FILES_DIR}/intermediate-ca.pem") - $(now)) / DAY ))
  if (( s_left < WINDOW_DAYS + 90 )); then
    log "WARNING: the Root CA rotation cannot start: the Intermediate CA has ${s_left} days left, less than the window plus 90 days (${WINDOW_DAYS} + 90)"
    return 1
  fi
}
root_due() {
  local t rleft sleft
  [[ -s "${FILES_DIR}/root-ca.pem" ]] || return 1
  t="$(now)"
  rleft=$(( ($(cert_enddate "${FILES_DIR}/root-ca.pem") - t) / DAY ))
  sleft=$(( ($(cert_enddate "${FILES_DIR}/intermediate-ca.pem") - t) / DAY ))
  # the own trigger; or earlier when the Intermediate CA is due and a new certificate for it could not outlive this root
  if (( rleft > WINDOW_DAYS + 365 )); then
    (( rleft <= 3 * WINDOW_DAYS + 455 && sleft <= 2 * WINDOW_DAYS + 365 )) || return 1
  fi
  root_preflight
}

root_steps() { echo "create switch admin retire"; }
root_gate() {
  case "$1" in
    create | switch) echo none ;;
    admin) echo restart ;;
    retire) echo "window coverage" ;;
  esac
}
# R_old expires: 30 days before, the wait is over (the approval is not)
root_deadline() {
  [[ "$1" == retire ]] || return 0
  local old pem
  old="$(root_data old)"
  [[ -n "${old}" ]] || return 0
  pem="${FILES_DIR}/$(root_file "$(root_alias "${old}")")"
  [[ -s "${pem}" ]] || pem="${FILES_DIR}/root-ca.pem"
  echo $(( $(cert_enddate "${pem}") - 30 * DAY ))
}
root_coverage_args() { echo "--issued-before $(root_data newChainAt)"; }

# --- create ----------------------------------------------------------------------------------
root_create_in() { # workdir
  local w="$1" old new s r_file c_alias c_file days rleft s_label
  old="$(root_data old)"; new="$(root_data new)"; s="$(root_data sNum)"
  s_label="intermediate-ca-$(printf '%02d' "${s}")"
  r_file="$(root_file "$(root_alias "${new}")")"
  c_alias="$(root_cross_alias "${s}")"; c_file="$(root_file "${c_alias}")"
  # R_new: self-signed by the key in KMS. An earlier run may have done it and been interrupted: the file is kept
  if [[ -s "${FILES_DIR}/${r_file}" ]] && openssl verify -CAfile "${FILES_DIR}/${r_file}" "${FILES_DIR}/${r_file}" > /dev/null 2>&1; then
    log "root: the certificate $(root_alias "${new}") exists already: continuing with it"
  else
    log "root: $(root_label "${new}") is self-signed, ${ROOT_DAYS} days"
    "${KMS_CA}" root-self-sign "$(root_label "${new}")" "${w}/r-new.pem" "${ROOT_DAYS}" > /dev/null \
      || { log "ERROR: $(root_label "${new}") could not be self-signed (is the key in PKI_KMS_CA_KEYS?)"; return 1; }
    [[ "$(openssl x509 -in "${w}/r-new.pem" -noout -ext basicConstraints 2> /dev/null)" == *"pathlen:3"* ]] || { log "ERROR: the new Root CA has not got pathlen 3"; return 1; }
    [[ "$(openssl x509 -in "${w}/r-new.pem" -noout -pubkey | openssl sha256)" != "$(openssl x509 -in "${FILES_DIR}/root-ca.pem" -noout -pubkey | openssl sha256)" ]] \
      || { log "ERROR: the new Root CA has the key of the old one"; return 1; }
    root_install "${w}/r-new.pem" "${r_file}" || return 1
  fi
  # C: the cross-certificate for the key of S (the same subject and key as intermediate-ca.pem, issued by R_new)
  "${KMS_CA}" csr "${s_label}" "${w}/s.csr" > /dev/null || { log "ERROR: no CSR for ${s_label}"; return 1; }
  if [[ -s "${FILES_DIR}/${c_file}" ]] \
     && [[ "$(openssl x509 -in "${FILES_DIR}/${c_file}" -noout -pubkey | openssl sha256)" == "$(openssl req -in "${w}/s.csr" -noout -pubkey | openssl sha256)" ]] \
     && openssl verify -CAfile "${FILES_DIR}/${r_file}" "${FILES_DIR}/${c_file}" > /dev/null 2>&1; then
    log "root: the cross-certificate ${c_alias} exists already: continuing with it"
  else
    rleft=$(( ($(cert_enddate "${FILES_DIR}/${r_file}") - $(now)) / DAY ))
    days="${INTERMEDIATE_DAYS}"
    (( rleft - 1 < days )) && days=$(( rleft - 1 ))
    log "root: $(root_label "${new}") issues the cross-certificate for ${s_label}, ${days} days, pathlen 2 (a Root CA signature)"
    "${KMS_CA}" issue-ca "$(root_label "${new}")" "${FILES_DIR}/${r_file}" "${w}/s.csr" "${w}/c.pem" "${days}" > /dev/null \
      || { log "ERROR: $(root_label "${new}") could not issue the cross-certificate"; return 1; }
    [[ "$(openssl x509 -in "${w}/c.pem" -noout -pubkey | openssl sha256)" == "$(openssl x509 -in "${FILES_DIR}/intermediate-ca.pem" -noout -pubkey | openssl sha256)" ]] \
      || { log "ERROR: the cross-certificate is not for the key of the Intermediate CA"; return 1; }
    [[ "$(openssl x509 -in "${w}/c.pem" -noout -subject)" == "$(openssl x509 -in "${FILES_DIR}/intermediate-ca.pem" -noout -subject)" ]] \
      || { log "ERROR: the cross-certificate has not the subject of the Intermediate CA"; return 1; }
    openssl verify -CAfile "${FILES_DIR}/${r_file}" "${w}/c.pem" > /dev/null 2>&1 || { log "ERROR: the cross-certificate does not chain to the new Root CA"; return 1; }
    [[ "$(openssl x509 -in "${w}/c.pem" -noout -ext basicConstraints 2> /dev/null)" == *"pathlen:2"* ]] || { log "ERROR: the cross-certificate has not got pathlen 2"; return 1; }
    root_install "${w}/c.pem" "${c_file}" || return 1
  fi
  trust_add "$(root_alias "${new}")" "${FILES_DIR}/${r_file}" server,phone,fed || return 1
  trust_add "${c_alias}" "${FILES_DIR}/${c_file}" server,phone,fed || return 1
  log "root: $(root_alias "${new}") and ${c_alias} are stored and in the manifest; the switch makes TAK Server and the enrolments use them"
}
# an atomic copy into the files directory
root_install() { # src dest(relative)
  mkdir -p "$(dirname "${FILES_DIR}/$2")"
  cp "$1" "${FILES_DIR}/$2.new" && chmod 644 "${FILES_DIR}/$2.new" && mv -f "${FILES_DIR}/$2.new" "${FILES_DIR}/$2"
}
root_create() {
  local old new w rc
  new="$(root_data new)"
  if [[ -z "${new}" ]]; then
    old="$(jq -r '.numbers.root' "${STATE_FILE}")"
    new="$(root_next_number)"
    [[ -n "${new}" ]] || { log "ERROR: PKI_KMS_CA_KEYS has no later Root CA generation"; return 1; }
    st_set --argjson o "${old}" --argjson n "${new}" --argjson s "$(jq -r '.numbers.intermediate' "${STATE_FILE}")" \
      '.active.data = {old: $o, new: $n, sNum: $s}' || return 1
  fi
  mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
  w="$(umask 077; mktemp -d "${TMPFS_DIR}/root.XXXXXX")" || return 1
  rc=0
  root_create_in "${w}" || rc=$?
  find "${w}" -delete 2> /dev/null
  return "${rc}"
}

# --- switch ----------------------------------------------------------------------------------
# Tells the operator what federation peers need before the retire step (SNS; the log has it too)
root_notify() {
  local new="$1" c_file="$2" msg topic="${PKI_ALERT_TOPIC_ARN:-}"
  msg="Root CA rotation: the new Root CA $(root_alias "${new}") is in use for new enrolments from now on.
SHA-256 fingerprints
  Root CA ($(root_alias "${new}")):  $(cert_fp "${FILES_DIR}/$(root_file "$(root_alias "${new}")")")
  Intermediate CA, cross-certificate:  $(cert_fp "${FILES_DIR}/${c_file}")
Federation peers: add the Root CA (and the cross-certificate; the FederateCA secret now holds it) to the truststore of the other server before the step 'retire' is approved. A peer that trusts our Intermediate CA certificate directly needs nothing.
Phones: nothing to do; a phone gets the new root when it enrols again. The step 'retire' waits for the active users to do that."
  log "root: for federation peers: $(cert_fp "${FILES_DIR}/$(root_file "$(root_alias "${new}")")") (Root CA ${new}), $(cert_fp "${FILES_DIR}/${c_file}") (cross-certificate)"
  if [[ -n "${topic}" ]]; then
    aws sns publish --topic-arn "${topic}" --subject "TAK.NZ ${PKI_ENV_LABEL:-} Root CA rotation: new root in use" --message "${msg}" > /dev/null 2>&1 \
      && log "the fingerprints were sent to the alert topic" || log "WARNING: could not publish to the alert topic"
  fi
}
root_switch() {
  local new s cl r_file c_file w rc=0
  new="$(root_data new)"; s="$(root_data sNum)"; cl="$(jq -r '.numbers.enrollment' "${STATE_FILE}")"
  [[ -n "${new}" && -n "${s}" ]] || { log "ERROR: the rotation has no numbers"; return 1; }
  r_file="$(root_file "$(root_alias "${new}")")"; c_file="$(root_file "$(root_cross_alias "${s}")")"
  trust_apply || rc=$?
  (( rc == 0 || rc == 10 )) || { log "ERROR: the truststores could not be changed"; return 1; }
  # from here on the new enrolments carry the new root: abort is refused
  [[ "$(root_data switchStarted)" == "true" ]] || st_set '.active.data.switchStarted = true' || return 1
  if [[ "$(root_data rechained)" != "true" ]]; then
    mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
    w="$(umask 077; mktemp -d "${TMPFS_DIR}/root.XXXXXX")" || return 1
    cat "${FILES_DIR}/${c_file}" "${FILES_DIR}/${r_file}" > "${w}/chain.pem"
    openssl pkcs12 -in "${TMPFS_DIR}/intermediate-ca-signing.p12" -passin "pass:${KS_PASS}" -nodes -nocerts -out "${w}/cl.key" 2> /dev/null \
      || { log "ERROR: cannot read the signing key"; find "${w}" -delete; return 1; }
    signing_keystore_build "${FILES_DIR}/enrollment-ca.pem" "${w}/cl.key" "${w}/chain.pem" "${w}/cl.p12" || { log "ERROR: could not build the keystore"; find "${w}" -delete; return 1; }
    signing_rechain "${cl}" "${w}/cl.p12" || { find "${w}" -delete; return 1; }
    root_install "${w}/chain.pem" enrollment-chain.pem || { find "${w}" -delete; return 1; }
    find "${w}" -delete
    st_set '.active.data.rechained = true' || return 1
  fi
  root_install "${FILES_DIR}/${c_file}" ca.pem || return 1
  root_notify "${new}" "${c_file}"
  log "root: new enrolments carry [Enrollment CA, $(root_cross_alias "${s}"), $(root_alias "${new}")]; the server certificate is unchanged"
  return 10
}

# --- admin -----------------------------------------------------------------------------------
root_admin() {
  if [[ "$(root_data adminDone)" != "true" ]]; then
    "${PKI_ROTATE_ADMIN_SCRIPT:-${SCRIPT_DIR}/admin-cert-rotate.sh}" rotate || return $?
    st_set '.active.data.adminDone = true' || return 1
  fi
  # from here on an enrolment carries the new root: the old task has been replaced (gate restart)
  [[ -n "$(root_data newChainAt)" ]] || st_set --argjson t "$(now)" '.active.data.newChainAt = $t' || return 1
  log "root: new enrolments carry the new root since $(fmt_date "$(root_data newChainAt)"); phones that enrolled before are the stragglers of the retire step"
}

# --- retire ----------------------------------------------------------------------------------
root_retire() {
  local old new s r_alias_old r_alias_new c_alias r_file_new c_file b_alias rc=0 f
  old="$(root_data old)"; new="$(root_data new)"; s="$(root_data sNum)"
  [[ -n "${old}" && -n "${new}" && -n "${s}" ]] || { log "ERROR: the rotation has no numbers"; return 1; }
  r_alias_old="$(root_alias "${old}")"; r_alias_new="$(root_alias "${new}")"; c_alias="$(root_cross_alias "${s}")"
  b_alias="$(printf 'intermediate-ca-%02d' "${s}")"
  r_file_new="$(root_file "${r_alias_new}")"; c_file="$(root_file "${c_alias}")"
  # 1. the manifest: R_new is the root, C the Intermediate CA; R_old and B go
  if [[ "$(jq -r '.numbers.root' "${STATE_FILE}")" == "${old}" ]]; then
    if [[ "$(jq -r --arg a "${r_alias_old}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]]; then
      trust_remove "${r_alias_old}" || return 1
    fi
    if [[ "$(jq -r --arg a "${c_alias}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]]; then
      trust_set_file "${b_alias}" "${c_file}" || return 1
      trust_remove "${c_alias}" || return 1
    fi
    # 2. the files and the state: from here the files of the PKI are the new ones
    root_install "${FILES_DIR}/${r_file_new}" root-ca.pem || return 1
    root_install "${FILES_DIR}/${c_file}" intermediate-ca.pem || return 1
    trust_state_set --argjson n "${new}" --arg cn "$("${KMS_CA}" common-name "$(root_label "${new}")")" \
      --arg rend "$(openssl x509 -in "${FILES_DIR}/root-ca.pem" -noout -enddate | cut -d= -f2)" \
      --arg send "$(openssl x509 -in "${FILES_DIR}/intermediate-ca.pem" -noout -enddate | cut -d= -f2)" \
      '.numbers.root = $n | .names.root = $cn | .notAfter.root = $rend | .notAfter.intermediate = $send' || return 1
  fi
  trust_apply || rc=$?
  (( rc == 0 || rc == 10 )) || { log "ERROR: the truststores could not be changed"; return 1; }
  # 3. the server certificate presents [L, C, R_new]; the admin certificate carries the same chain (no restart of their own)
  if [[ "$(root_data retLeaf)" != "true" ]]; then
    PKI_ROTATE_NO_DEPLOY=1 "${PKI_ROTATE_SERVER_SCRIPT:-${SCRIPT_DIR}/server-cert-rotate.sh}" rotate || { log "ERROR: the server certificate could not be re-issued"; return 1; }
    st_set '.active.data.retLeaf = true' || return 1
  fi
  if [[ "$(root_data retAdmin)" != "true" ]]; then
    "${PKI_ROTATE_ADMIN_SCRIPT:-${SCRIPT_DIR}/admin-cert-rotate.sh}" rotate || { log "ERROR: the admin certificate could not be re-issued"; return 1; }
    st_set '.active.data.retAdmin = true' || return 1
  fi
  for f in "$(root_file "${r_alias_old}")" "$(root_file "${b_alias}")"; do
    [[ "${FILES_DIR}/${f}" != "${FILES_DIR}/${c_file}" ]] && find "${FILES_DIR}/${f}" -delete 2> /dev/null
  done
  "${METRICS}" emit RootCARotated 1 || true
  log "root: ${r_alias_old} is retired: the server presents [L, ${c_alias}, ${r_alias_new}]. Its KMS key is still there and the signer role can use it: remove generation ${old} from pki.kmsCa.rootCaNumbers (a CDK deploy drops it from the role policy; the key is retained), then schedule its deletion in KMS with a 30-day window"
  return 10
}

root_run() {
  case "$1" in
    create) root_create ;;
    switch) root_switch ;;
    admin) root_admin ;;
    retire) root_retire ;;
    *) log "root: unknown step '$1'"; return 1 ;;
  esac
}

# Before the switch everything that `create` made is removed (the KMS keys are not touched). After it new enrolments
# carry the new root and the rotation can only go on.
root_abort() {
  local new s r_file c_file f rc=0
  new="$(root_data new)"; s="$(root_data sNum)"
  [[ -n "${new}" ]] || return 0
  if [[ "$(root_data switchStarted)" == "true" ]]; then
    log "root: new enrolments carry $(root_alias "${new}") already: this rotation can only go on. It waits at its next gate, nothing is lost"
    return 2
  fi
  r_file="$(root_file "$(root_alias "${new}")")"; c_file="$(root_file "$(root_cross_alias "${s}")")"
  for f in "$(root_alias "${new}")" "$(root_cross_alias "${s}")"; do
    if [[ "$(jq -r --arg a "${f}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]]; then trust_remove "${f}" || return 1; fi
  done
  trust_apply || rc=$?
  (( rc == 0 || rc == 10 )) || return 1
  find "${FILES_DIR}/${r_file}" "${FILES_DIR}/${c_file}" -delete 2> /dev/null
  (( rc == 10 )) && { trigger_deployment || log "WARNING: the rolling deployment could not be started"; }
  log "root: the preparation of $(root_alias "${new}") is undone (its key in KMS is untouched)"
  return 0
}
