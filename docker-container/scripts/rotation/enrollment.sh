#!/bin/bash
# rotation/enrollment.sh - the rotation of the Enrollment Signing CA (Cl) (#135, scenario of pki-rotate.sh, #171).
# Sourced by pki-rotate.sh; it has no main. Read the header of pki-rotate.sh for the contract of a scenario.
#
# What changes. Cl signs the client certificates of the phones (enrolment) and the admin certificate. Its key is a
# software key in a secret, so it can be replaced without KMS: a new Cl is made, signed by the Intermediate CA S (the
# key in KMS), and TAK Server gets it at a restart. Phones keep their certificates, which chain to the old Cl, so
# both Cl are trusted until every phone has a certificate from the new one.
#
#   create   A key and a certificate for Cl NN (the next number, signed by S with the days that S has left, at most
#            PKI_ENROLLMENT_CA_DAYS), checked against S and R. Stored as the secret <StackName>/TAK-Server/Enrollment-CA-NN,
#            added to the trust manifest (server set) and given an empty CRL. Nothing signs with it yet.
#   switch   The server truststore gets both Cl (trust_apply), the new Cl becomes the signing keystore (tmpfs,
#            pki-state.json, enrollment-ca.pem) and the certificate of the old one moves to trust-certs/. TAK Server
#            restarts: from then on it enrols with Cl NN and accepts the certificates of both. Point of no return.
#   admin    (gate restart: the task runs a keystore of the new Cl) the admin certificate is rotated: it is signed by Cl NN.
#   retire   (gates window, coverage, approval; deadline: 30 days before the old Cl expires) the old Cl is removed from
#            the truststores, its CRL is deleted, its key is destroyed (the secret is deleted with a recovery window of
#            30 days), TAK Server restarts. Every certificate that the old Cl issued stops working.
#
# Starts when the certificate of the current Cl is PKI_ENROLLMENT_CA_ROTATION_DAYS (365) old, there is only one Cl in
# the manifest, and S has more life left than the new Cl needs (the rotation of S is #172).
# State of the rotation (old and new number) is in rotation-state.json `.active.data`. Abort undoes create and switch's
# preparation; after the switch it refuses (return 2).

enrollment_cn() { "${KMS_CA}" common-name "$(printf 'enrollment-ca-%02d' "$1")"; }
enrollment_alias() { printf 'enrollment-ca-%02d' "$1"; }
enrollment_copy_of() { echo "trust-certs/$(enrollment_alias "$1").pem"; } # relative to the files directory
enrollment_data() { st_get ".active.data.$1 // empty"; }

enrollment_summary() {
  local pem="${FILES_DIR}/enrollment-ca.pem"
  echo "$(jq -r .names.enrollment "${STATE_FILE}")|$(cert_enddate "${pem}")|$(( $(cert_startdate "${pem}") + CL_ROTATION_DAYS * DAY ))|age ${CL_ROTATION_DAYS} days"
}

# What a rotation needs to start, whatever the trigger (`pki-rotate.sh start` checks only this): one Enrollment CA in the
# manifest, and an Intermediate CA with enough life for a new one under it
enrollment_preflight() {
  local n s_left
  trust_ensure_manifest || return 1
  n="$(crl_aliases | grep -c .)" || true
  if (( n != 1 )); then
    log "enrollment: the manifest lists ${n} Enrollment CAs: no rotation until there is one"
    return 1
  fi
  s_left=$(( ($(cert_enddate "${FILES_DIR}/intermediate-ca.pem") - $(now)) / DAY ))
  if (( s_left - 1 < CL_ROTATION_DAYS + WINDOW_DAYS )); then
    log "WARNING: the Intermediate CA has ${s_left} days left, not the $(( CL_ROTATION_DAYS + WINDOW_DAYS + 1 )) that a new Enrollment CA needs (age ${CL_ROTATION_DAYS} + window ${WINDOW_DAYS}): the Intermediate CA has to be rotated first (#172)"
    return 1
  fi
}
enrollment_due() {
  local pem="${FILES_DIR}/enrollment-ca.pem" t age s_left
  [[ -s "${pem}" ]] || return 1
  t="$(now)"
  age=$(( (t - $(cert_startdate "${pem}")) / DAY ))
  (( age >= CL_ROTATION_DAYS )) || return 1
  s_left=$(( ($(cert_enddate "${FILES_DIR}/intermediate-ca.pem") - t) / DAY ))
  # The Intermediate CA rotation (#172) makes a new Enrollment CA itself, and it must start at its trigger: a rotation of
  # the Enrollment CA that takes W and more would eat the margin that the trigger leaves
  if (( s_left <= 2 * WINDOW_DAYS + 365 )); then
    log "enrollment: the Enrollment CA is ${age} days old and due, but the Intermediate CA has ${s_left} days left (its rotation starts at $(( 2 * WINDOW_DAYS + 365 )) or fewer): the Intermediate CA has to be rotated first (#172), which makes a new Enrollment CA"
    return 1
  fi
  enrollment_preflight
}
enrollment_steps() { echo "create switch admin retire"; }
enrollment_gate() {
  case "$1" in
    create | switch) echo none ;;
    admin) echo restart ;;
    retire) echo "window coverage" ;;
  esac
}
# the old Cl expires: 30 days before, the wait for the window and for the phones is over
enrollment_deadline() {
  [[ "$1" == retire ]] || return 0
  local old pem
  old="$(enrollment_data old)"
  [[ -n "${old}" ]] || return 0
  pem="${FILES_DIR}/$(enrollment_copy_of "${old}")"
  [[ -s "${pem}" ]] || return 0
  echo $(( $(cert_enddate "${pem}") - 30 * DAY ))
}
enrollment_coverage_args() { echo "--issuer $(enrollment_alias "$(enrollment_data old)")"; }

enrollment_new_number() {
  local cur hi
  cur="$(jq -r '.numbers.enrollment' "${STATE_FILE}")"
  hi="$(jq -r '.enrollmentHighest // 0' "${STATE_FILE}")"
  echo $(( (cur > hi ? cur : hi) + 1 ))
}

# --- create ----------------------------------------------------------------------------------
# The issuer of the new Enrollment CA and the chain above it are the current Intermediate CA S and [S, R] by default. The
# Intermediate CA rotation (#172) sets ENROLLMENT_ISSUER_LABEL, ENROLLMENT_ISSUER_PEM and ENROLLMENT_CHAIN (the chain file
# above the new Cl: [A, S_old, R]) for a new Enrollment CA under the new Intermediate CA.
enrollment_create_in() { # workdir new
  local w="$1" new="$2" alias secret days s_left p12="$1/cl.p12" issuer_label issuer_pem chain
  issuer_label="${ENROLLMENT_ISSUER_LABEL:-intermediate-ca-$(printf '%02d' "$(jq -r '.numbers.intermediate' "${STATE_FILE}")")}"
  issuer_pem="${ENROLLMENT_ISSUER_PEM:-${FILES_DIR}/intermediate-ca.pem}"
  chain="${ENROLLMENT_CHAIN:-$(enrollment_chain_file)}"
  alias="$(enrollment_alias "${new}")"
  secret="$(signing_secret_name "${new}")"
  if aws secretsmanager describe-secret --secret-id "${secret}" > /dev/null 2>&1; then
    # an earlier run stored it and was interrupted: use that key, make no other
    log "enrollment: the secret ${secret} exists: continuing with it"
    signing_fetch "${new}" "${p12}" || { log "ERROR: cannot read the secret ${secret}"; return 1; }
    openssl pkcs12 -in "${p12}" -passin "pass:${KS_PASS}" -clcerts -nokeys -out "${w}/cl.pem" 2> /dev/null || { log "ERROR: cannot read the keystore of ${secret}"; return 1; }
  else
    s_left=$(( ($(cert_enddate "${issuer_pem}") - $(now)) / DAY ))
    days="${ENROLLMENT_DAYS}"
    (( s_left - 1 < days )) && days=$(( s_left - 1 ))
    if (( days < CL_ROTATION_DAYS + WINDOW_DAYS )); then
      log "ERROR: the issuer has ${s_left} days left: a new Enrollment CA would get ${days} days, less than the ${CL_ROTATION_DAYS} + ${WINDOW_DAYS} that the rotation needs"
      return 1
    fi
    log "enrollment: new ${alias} for ${days} days, signed by ${issuer_label}"
    openssl genrsa -out "${w}/cl.key" 2048 2> /dev/null || { log "ERROR: could not generate the key"; return 1; }
    openssl req -new -key "${w}/cl.key" -subj "/O=TAK.NZ/CN=$(enrollment_cn "${new}")" -out "${w}/cl.csr" || { log "ERROR: could not build the CSR"; return 1; }
    "${KMS_CA}" issue-ca "${issuer_label}" "${issuer_pem}" "${w}/cl.csr" "${w}/cl.pem" "${days}" > /dev/null \
      || { log "ERROR: ${issuer_label} could not sign the new Enrollment CA"; return 1; }
    openssl verify -CAfile <(roots_cat) -untrusted <(chain_without_last "${chain}") "${w}/cl.pem" > /dev/null 2>&1 \
      || { log "ERROR: the new Enrollment CA does not chain to the Root CA"; return 1; }
    [[ "$(pub_of_key "${w}/cl.key")" == "$(pub_of_cert "${w}/cl.pem")" ]] || { log "ERROR: the new certificate does not match its key"; return 1; }
    signing_keystore_build "${w}/cl.pem" "${w}/cl.key" "${chain}" "${p12}" || { log "ERROR: could not build the keystore"; return 1; }
    signing_store "${new}" "${p12}" || return 1
  fi
  trust_add "${alias}" "${w}/cl.pem" server || return 1
  crl_ensure "${alias}" || [[ $? == 10 ]] || return 1
  log "enrollment: ${alias} is stored and trusted by the manifest; the switch makes TAK Server use it"
}
enrollment_create() {
  local old new w rc
  old="$(jq -r '.numbers.enrollment' "${STATE_FILE}")"
  new="$(enrollment_data new)"
  if [[ -z "${new}" ]]; then
    new="$(enrollment_new_number)"
    (( new <= 99 )) || { log "ERROR: Enrollment CA numbers go up to 99"; return 1; }
    st_set --argjson o "${old}" --argjson n "${new}" '.active.data = {old: $o, new: $n}' || return 1
  fi
  mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
  w="$(umask 077; mktemp -d "${TMPFS_DIR}/enrollment.XXXXXX")" || return 1
  rc=0
  enrollment_create_in "${w}" "${new}" || rc=$?
  find "${w}" -delete 2> /dev/null
  return "${rc}"
}

# --- switch ----------------------------------------------------------------------------------
enrollment_switch() { enrollment_activate "$(enrollment_data old)" "$(enrollment_data new)"; }
# Makes Enrollment CA NEW the signing CA; OLD stays trusted. ENROLLMENT_NEW_CHAIN (a chain file) becomes enrollment-chain.pem
# when it is set (the bridge of an Intermediate CA rotation, #172).
enrollment_activate() { # old new
  local old="$1" new="$2" new_alias old_alias w p12 copy rc=0
  [[ -n "${old}" && -n "${new}" ]] || { log "ERROR: the rotation has no old and new number"; return 1; }
  old_alias="$(enrollment_alias "${old}")"; new_alias="$(enrollment_alias "${new}")"
  # 1. the server truststore holds both Enrollment CAs
  trust_apply || rc=$?
  (( rc == 0 || rc == 10 )) || { log "ERROR: the truststores could not be changed"; return 1; }
  # 2. the certificate of the old Cl gets a file of its own, before enrollment-ca.pem is overwritten
  copy="$(enrollment_copy_of "${old}")"
  if [[ ! -s "${FILES_DIR}/${copy}" ]]; then
    [[ "$(jq -r '.numbers.enrollment' "${STATE_FILE}")" == "${old}" ]] || { log "ERROR: ${FILES_DIR}/${copy} is missing and the old Enrollment CA is not current"; return 1; }
    mkdir -p "${FILES_DIR}/trust-certs"
    cp "${FILES_DIR}/enrollment-ca.pem" "${FILES_DIR}/${copy}.new" && chmod 644 "${FILES_DIR}/${copy}.new" && mv -f "${FILES_DIR}/${copy}.new" "${FILES_DIR}/${copy}" || return 1
  fi
  trust_set_file "${old_alias}" "${copy}" || return 1
  # 3. the new Cl signs from now on
  mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
  w="$(umask 077; mktemp -d "${TMPFS_DIR}/enrollment.XXXXXX")" || return 1
  p12="${w}/cl.p12"
  if ! signing_fetch "${new}" "${p12}"; then log "ERROR: cannot read the secret of ${new_alias}"; find "${w}" -delete; return 1; fi
  if [[ "$(openssl pkcs12 -in "${p12}" -passin "pass:${KS_PASS}" -clcerts -nokeys 2> /dev/null | openssl x509 -noout -fingerprint -sha256 2> /dev/null)" \
        != "$(openssl x509 -in "${FILES_DIR}/$(enrollment_copy_of "${new}")" -noout -fingerprint -sha256 2> /dev/null)" ]]; then
    log "ERROR: the secret of ${new_alias} holds another certificate than the manifest"; find "${w}" -delete; return 1
  fi
  signing_activate "${new}" "${p12}" || { find "${w}" -delete; return 1; }
  find "${w}" -delete
  if [[ -n "${ENROLLMENT_NEW_CHAIN:-}" ]]; then
    cp "${ENROLLMENT_NEW_CHAIN}" "${FILES_DIR}/enrollment-chain.pem.new" && chmod 644 "${FILES_DIR}/enrollment-chain.pem.new" \
      && mv -f "${FILES_DIR}/enrollment-chain.pem.new" "${FILES_DIR}/enrollment-chain.pem" || return 1
  fi
  cp "${FILES_DIR}/$(enrollment_copy_of "${new}")" "${FILES_DIR}/enrollment-ca.pem.new" && chmod 644 "${FILES_DIR}/enrollment-ca.pem.new" \
    && mv -f "${FILES_DIR}/enrollment-ca.pem.new" "${FILES_DIR}/enrollment-ca.pem" || return 1
  trust_state_set --arg cn "$(enrollment_cn "${new}")" --arg endate "$(openssl x509 -in "${FILES_DIR}/enrollment-ca.pem" -noout -enddate | cut -d= -f2)" \
    '.names.enrollment = $cn | .notAfter.enrollment = $endate' || return 1
  "${METRICS}" emit SigningCARotated 1 || true
  log "enrollment: ${new_alias} signs from now on; ${old_alias} stays trusted. TAK Server loads both at its restart"
  return 10
}

# --- admin -----------------------------------------------------------------------------------
enrollment_admin() { enrollment_admin_for "$(enrollment_data new)"; }
enrollment_admin_for() { # number of the Enrollment CA that signs the admin certificate
  local new="$1"
  # an earlier run rotated the certificate already and was interrupted before it saved that
  if openssl verify -no_check_time -partial_chain -CAfile "${FILES_DIR}/$(enrollment_copy_of "${new}")" <(openssl x509 -in "${FILES_DIR}/admin.pem") > /dev/null 2>&1; then
    log "enrollment: the admin certificate is signed by $(enrollment_alias "${new}") already"
    return 0
  fi
  "${PKI_ROTATE_ADMIN_SCRIPT:-${SCRIPT_DIR}/admin-cert-rotate.sh}" rotate
}

# --- retire ----------------------------------------------------------------------------------
enrollment_retire() { enrollment_retire_cl "$(enrollment_data old)"; }
# Retires Enrollment CA OLD: out of the truststores, CRL deleted, key destroyed. A caller may have removed other CA
# certificates from the manifest before (the Intermediate CA rotation does): one truststore change for all.
enrollment_retire_cl() { # old
  local old="$1" alias rc=0
  [[ -n "${old}" ]] || { log "ERROR: the rotation has no old number"; return 1; }
  alias="$(enrollment_alias "${old}")"
  [[ "$(jq -r '.numbers.enrollment' "${STATE_FILE}")" != "${old}" ]] || { log "ERROR: ${alias} is the current Enrollment CA"; return 1; }
  if [[ "$(jq -r --arg a "${alias}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]]; then
    trust_remove "${alias}" || return 1
  fi
  trust_apply || rc=$?
  (( rc == 0 || rc == 10 )) || { log "ERROR: the truststores could not be changed"; return 1; }
  crl_retire "${alias}" || return 1
  signing_destroy "${old}" || return 1
  find "${FILES_DIR}/$(enrollment_copy_of "${old}")" -delete 2> /dev/null
  # admin certificates of this CA that were not revoked yet need no CRL entry any more: nothing trusts their CA
  trust_state_set --arg a "${alias}" 'if .adminPrevious then .adminPrevious |= map(if .issuerAlias == $a and ((.revokedAt // "") == "") then .revokedAt = "retired" else . end) else . end' \
    || log "WARNING: could not update ${STATE_FILE}"
  log "enrollment: ${alias} is retired: its certificates stop working at the restart"
  return 10
}

enrollment_run() {
  case "$1" in
    create) enrollment_create ;;
    switch) enrollment_switch ;;
    admin) enrollment_admin ;;
    retire) enrollment_retire ;;
    *) log "enrollment: unknown step '$1'"; return 1 ;;
  esac
}

# Before the switch everything that create made is removed. After it the new Cl is in use and its certificates may
# exist: the rotation goes on (return 2).
enrollment_abort() {
  local new rc
  new="$(enrollment_data new)"
  [[ -n "${new}" ]] || return 0
  rc=0; enrollment_undo_create "${new}" || rc=$?
  return "${rc}"
}
# Undoes `create` of Enrollment CA NEW; 2 when it signs already
enrollment_undo_create() { # new
  local new="$1" alias rc=0
  if [[ "$(jq -r '.numbers.enrollment' "${STATE_FILE}")" == "${new}" ]]; then
    log "enrollment: $(enrollment_alias "${new}") signs already: this rotation can only go on (retire the old one when its time has come)"
    return 2
  fi
  alias="$(enrollment_alias "${new}")"
  if [[ "$(jq -r --arg a "${alias}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]]; then
    trust_remove "${alias}" || return 1
  fi
  trust_apply || rc=$?
  (( rc == 0 || rc == 10 )) || return 1
  crl_retire "${alias}" || return 1
  signing_destroy "${new}" || return 1
  find "${FILES_DIR}/$(enrollment_copy_of "${new}")" -delete 2> /dev/null
  # the truststore files changed back: a node that restarted in between loaded the new one
  (( rc == 10 )) && { trigger_deployment || log "WARNING: the rolling deployment could not be started"; }
  log "enrollment: the preparation of ${alias} is undone (its secret is deleted with a recovery window of ${SIGNING_RECOVERY_DAYS} days)"
  return 0
}
