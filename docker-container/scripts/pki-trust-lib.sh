#!/bin/bash
# pki-trust-lib.sh - what TAK Server trusts and what it signs enrolments with (#171, slice B).
# Sourced by pki-bootstrap.sh and by the rotation scenarios; no state of its own. Needs log, KS_PASS, FILES_DIR,
# STATE_FILE, TMPFS_DIR, SIGNING_ALIAS and jks_from_p12 from pki-bootstrap.sh.
#
# The truststores
# ---------------
# Which CA certificates a truststore holds is a manifest in pki-state.json (`.trust.entries`): alias, file (relative
# to the files directory) and the sets it belongs to.
#   server  truststore-intermediate-ca.jks/.p12   what TAK Server trusts: R, S and every live Enrollment CA, because
#                                                  ATAK sends only its leaf certificate (#133)
#   phone   truststore-phone.jks/.p12             what a data package gives a phone: S and R
#   fed     fed-truststore.jks                    what federation peers are checked against: S and R
# `trust_apply` rebuilds the files from the manifest, so a rotation changes the manifest and applies it. It is the
# only place that writes these files. TAK Server reads them only at start: `trust_apply` returns 10 when it changed
# something, which tells the orchestrator to restart (pki-rotate.sh).
#
# The signing keystore
# --------------------
# The Enrollment CA key is a software key in a Secrets Manager secret per generation
# (<StackName>/TAK-Server/Enrollment-CA-NN, created here at run time: the task role may create secrets with that
# prefix, and delete them with a recovery window of 30 days). `signing_store` stores a new generation as a secret;
# `signing_activate` makes it the current one in pki-state.json (`.enrollmentSecret`) and puts it into this node's
# tmpfs (`signing_install` does both). A node that starts later restores the current one (pki-bootstrap.sh). The old
# secret stays until the rotation retires it (`signing_destroy`).
TRUST_SETS=(server phone fed)
trust_jks_name() { case "$1" in server) echo truststore-intermediate-ca.jks ;; phone) echo truststore-phone.jks ;; fed) echo fed-truststore.jks ;; esac; }
trust_p12_name() { case "$1" in server) echo truststore-intermediate-ca.p12 ;; phone) echo truststore-phone.p12 ;; esac; }
TRUST_MARKER="${FILES_DIR}/.trust-apply.pending"

# The manifest of a new PKI: R and S for everyone, Enrollment CA 01 for the server only.
trust_default_manifest() {
  jq -n '{entries: [
    {alias: "root-ca-01", file: "root-ca.pem", sets: ["server", "phone", "fed"]},
    {alias: "intermediate-ca-01", file: "intermediate-ca.pem", sets: ["server", "phone", "fed"]},
    {alias: "enrollment-ca-01", file: "enrollment-ca.pem", sets: ["server"]}]}'
}
# A PKI that was built before the manifest existed gets the default one.
trust_ensure_manifest() {
  [[ "$(jq -r '.trust.entries | length // 0' "${STATE_FILE}" 2> /dev/null)" -gt 0 ]] && return 0
  jq --argjson t "$(trust_default_manifest | jq -c '{entries: .entries}')" '.trust = $t' "${STATE_FILE}" > "${STATE_FILE}.new" \
    && chmod 644 "${STATE_FILE}.new" && mv -f "${STATE_FILE}.new" "${STATE_FILE}"
}
trust_state_set() { # jq arguments
  jq "$@" "${STATE_FILE}" > "${STATE_FILE}.new" && chmod 644 "${STATE_FILE}.new" && mv -f "${STATE_FILE}.new" "${STATE_FILE}"
}
cert_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2> /dev/null | cut -d= -f2; }
# "alias fingerprint" for every entry of a JKS, sorted
jks_entries() {
  keytool -list -keystore "$1" -storepass "${KS_PASS}" 2> /dev/null \
    | awk '/trustedCertEntry|PrivateKeyEntry/ {split($0, a, ","); alias = a[1]} /SHA-256\)/ {print alias, $NF}' | sort
}

# Builds the truststores of a manifest into a directory. certdir is where the files of the manifest are.
trust_build() { # manifest certdir outdir
  local manifest="$1" certdir="$2" out="$3" set jks p12 alias file
  mkdir -p "${out}"
  for set in "${TRUST_SETS[@]}"; do
    jks="${out}/$(trust_jks_name "${set}")"
    rm -f "${jks}"
    while IFS=$'\t' read -r alias file; do
      [[ -s "${certdir}/${file}" ]] || { log "trust: ${certdir}/${file} (${alias}) is missing"; return 1; }
      keytool -import -trustcacerts -file "${certdir}/${file}" -alias "${alias}" -keystore "${jks}" -storepass "${KS_PASS}" -noprompt > /dev/null 2>&1 \
        || { log "trust: could not add ${alias} to ${jks##*/}"; return 1; }
    done < <(jq -r --arg s "${set}" '.entries[] | select(.sets | index($s)) | [.alias, .file] | @tsv' "${manifest}")
    [[ -f "${jks}" ]] || { log "trust: the set ${set} would be empty"; return 1; }
    p12="$(trust_p12_name "${set}")"
    if [[ -n "${p12}" ]]; then
      rm -f "${out}/${p12}"
      keytool -importkeystore -srckeystore "${jks}" -srcstoretype JKS -srcstorepass "${KS_PASS}" \
        -destkeystore "${out}/${p12}" -deststoretype PKCS12 -deststorepass "${KS_PASS}" > /dev/null 2>&1 \
        || { log "trust: could not build ${p12}"; return 1; }
    fi
  done
}

# The entries the manifest says a set must hold: "alias fingerprint", sorted
trust_expected() { # manifest certdir set
  local alias file
  while IFS=$'\t' read -r alias file; do
    echo "${alias} $(cert_fp "$2/${file}")"
  done < <(jq -r --arg s "$3" '.entries[] | select(.sets | index($s)) | [.alias, .file] | @tsv' "$1") | sort
}
# Do the files in a directory hold what the manifest says?
trust_matches() { # manifest certdir dir
  local set
  for set in "${TRUST_SETS[@]}"; do
    [[ -s "$3/$(trust_jks_name "${set}")" ]] || return 1
    [[ "$(jks_entries "$3/$(trust_jks_name "${set}")")" == "$(trust_expected "$1" "$2" "${set}")" ]] || return 1
    [[ -z "$(trust_p12_name "${set}")" ]] || [[ -s "$3/$(trust_p12_name "${set}")" ]] || return 1
  done
}
trust_files() { # every file the truststores consist of
  local set
  for set in "${TRUST_SETS[@]}"; do
    trust_jks_name "${set}"
    [[ -z "$(trust_p12_name "${set}")" ]] || trust_p12_name "${set}"
  done
}

# CA certificates that a manifest entry points to
trust_add() { # alias pemfile sets (comma separated)
  local alias="$1" pem="$2" sets="$3" dest set
  [[ "${alias}" =~ ^[a-z][a-z0-9-]*$ ]] || { log "trust: invalid alias '${alias}'"; return 1; }
  openssl x509 -in "${pem}" -noout > /dev/null 2>&1 || { log "trust: ${pem} is not a certificate"; return 1; }
  [[ "$(openssl x509 -in "${pem}" -noout -ext basicConstraints 2> /dev/null)" == *"CA:TRUE"* ]] || { log "trust: ${alias} is not a CA certificate"; return 1; }
  for set in ${sets//,/ }; do
    [[ " ${TRUST_SETS[*]} " == *" ${set} "* ]] || { log "trust: unknown set '${set}' (use ${TRUST_SETS[*]})"; return 1; }
  done
  # it must chain to what is trusted already (the Root CA, through the Intermediate CA), so a wrong file cannot be added by mistake
  if [[ "$(jq -r --arg a "${alias}" '[.trust.entries[] | select(.alias == $a)] | length' "${STATE_FILE}")" == "0" ]]; then
    openssl verify -CAfile "${FILES_DIR}/root-ca.pem" -untrusted "${FILES_DIR}/intermediate-ca.pem" "${pem}" > /dev/null 2>&1 \
      || [[ "$(openssl x509 -in "${pem}" -noout -subject)" == "$(openssl x509 -in "${pem}" -noout -issuer | sed 's/^issuer=/subject=/')" ]] \
      || { log "trust: ${alias} does not chain to the Root CA through the Intermediate CA"; return 1; }
  fi
  mkdir -p "${FILES_DIR}/trust-certs"
  dest="trust-certs/${alias}.pem"
  if [[ "$(readlink -f "${pem}")" != "$(readlink -f "${FILES_DIR}/${dest}")" ]]; then
    cp "${pem}" "${FILES_DIR}/${dest}.new" && chmod 644 "${FILES_DIR}/${dest}.new" && mv -f "${FILES_DIR}/${dest}.new" "${FILES_DIR}/${dest}" || return 1
  fi
  trust_ensure_manifest || return 1
  trust_state_set --arg a "${alias}" --arg f "${dest}" --argjson sets "$(printf '%s\n' ${sets//,/ } | jq -R . | jq -s -c .)" \
    '.trust.entries = ([.trust.entries[] | select(.alias != $a)] + [{alias: $a, file: $f, sets: $sets}])'
}
trust_remove() { # alias
  trust_ensure_manifest || return 1
  [[ "$(jq -r --arg a "$1" '[.trust.entries[] | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]] || { log "trust: ${1} is not in the manifest"; return 1; }
  trust_state_set --arg a "$1" '.trust.entries |= map(select(.alias != $a))'
}

# Points the manifest entry of an alias at another file with the same certificate (the file of the current Enrollment CA
# moves to trust-certs/ when a new one takes over enrollment-ca.pem)
trust_set_file() { # alias file(relative to the files directory)
  [[ "$(jq -r --arg a "$1" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" != "0" ]] || { log "trust: ${1} is not in the manifest"; return 1; }
  openssl x509 -in "${FILES_DIR}/$2" -noout > /dev/null 2>&1 || { log "trust: ${FILES_DIR}/$2 is not a certificate"; return 1; }
  trust_state_set --arg a "$1" --arg f "$2" '.trust.entries |= map(if .alias == $a then .file = $f else . end)'
}

trust_restore_previous() {
  local f ok=0
  while IFS= read -r f; do
    if [[ -s "${FILES_DIR}/${f}.prev" ]]; then
      cp -p "${FILES_DIR}/${f}.prev" "${FILES_DIR}/${f}.restore" && mv -f "${FILES_DIR}/${f}.restore" "${FILES_DIR}/${f}" || ok=1
    else
      log "trust: no ${f}.prev to restore"; ok=1
    fi
  done < <(trust_files)
  return "${ok}"
}
# A marker means the swap of an earlier apply did not finish: restore the .prev copies.
trust_recover() {
  [[ -f "${TRUST_MARKER}" ]] || return 0
  log "WARNING: a change of the truststores was interrupted (${TRUST_MARKER}): restoring the previous files"
  if trust_restore_previous; then find "${TRUST_MARKER}" -delete; log "the previous truststores are back in place"; return 0; fi
  log "ERROR: could not restore the previous truststores; the marker stays"
  return 1
}
# Rebuild the truststores from the manifest. 0 nothing changed, 10 changed (TAK Server must restart), 1 failed
# (the previous files are back). Test hook: PKI_TRUST_BREAK_INSTALL=1 damages one installed file.
trust_apply() {
  local manifest work f rc=0 out
  mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}" || return 1
  trust_recover || return 1
  trust_ensure_manifest || { log "trust: cannot write the manifest"; return 1; }
  work="$(mktemp -d "${TMPFS_DIR}/trust.XXXXXX")" || { log "trust: cannot make a work directory"; return 1; }
  manifest="${work}/manifest.json"
  jq '.trust' "${STATE_FILE}" > "${manifest}" || return 1
  out="${work}/new"
  if ! trust_build "${manifest}" "${FILES_DIR}" "${out}"; then find "${work}" -delete; return 1; fi
  if ! trust_matches "${manifest}" "${FILES_DIR}" "${out}"; then log "trust: the new truststores do not hold what the manifest says"; find "${work}" -delete; return 1; fi
  if trust_matches "${manifest}" "${FILES_DIR}" "${FILES_DIR}"; then
    log "the truststores already hold what the manifest says: nothing to do"
    find "${work}" -delete
    return 0
  fi
  log "changing the truststores: $(jq -r '[.entries[] | "\(.alias) (\(.sets | join(",")))"] | join(", ")' "${manifest}")"
  printf '{"started":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${TRUST_MARKER}" || { find "${work}" -delete; return 1; }
  while IFS= read -r f; do
    if [[ -f "${FILES_DIR}/${f}" ]]; then cp -p "${FILES_DIR}/${f}" "${FILES_DIR}/${f}.prev" || rc=1; fi
  done < <(trust_files)
  if (( rc == 0 )); then
    while IFS= read -r f; do
      cp "${out}/${f}" "${FILES_DIR}/${f}.new" && chmod 644 "${FILES_DIR}/${f}.new" && mv -f "${FILES_DIR}/${f}.new" "${FILES_DIR}/${f}" || { rc=1; break; }
    done < <(trust_files)
  fi
  [[ "${PKI_TRUST_BREAK_INSTALL:-0}" == "1" ]] && echo "broken" > "${FILES_DIR}/truststore-intermediate-ca.jks"
  if (( rc == 0 )) && trust_matches "${manifest}" "${FILES_DIR}" "${FILES_DIR}"; then
    find "${TRUST_MARKER}" -delete
    find "${work}" -delete
    return 10
  fi
  log "ERROR: installing the truststores failed; restoring the previous files"
  trust_restore_previous && find "${TRUST_MARKER}" -delete
  find "${work}" -delete
  return 1
}

# ---------------------------------------------------------------------------------------------
# The signing keystore: [Cl key + chain Cl, S, R]
# ---------------------------------------------------------------------------------------------
signing_current_secret() { local s; s="$(jq -r '.enrollmentSecret // empty' "${STATE_FILE}" 2> /dev/null)"; echo "${s:-${PKI_ENROLLMENT_CA_SECRET:-}}"; }
signing_secret_name() { printf '%s/TAK-Server/Enrollment-CA-%02d' "${StackName:?StackName is not set}" "$1"; }
# A PKCS#12 with the key and the chain [Cl, S, R], the file that TAK Server's CA config and the secret hold
signing_keystore_build() { # cl.pem cl.key s.pem r.pem out.p12
  local chain
  chain="$(mktemp "${TMPFS_DIR}/chain.XXXXXX")" || return 1
  cat "$3" "$4" > "${chain}"
  openssl pkcs12 -export -in "$1" -inkey "$2" -certfile "${chain}" -name "${SIGNING_ALIAS}" -out "$5" -passout "pass:${KS_PASS}" 2> /dev/null
  local rc=$?
  find "${chain}" -delete
  return "${rc}"
}
# The keystore of generation N, from its secret, into a file (generation 1 is the secret of the stack)
signing_fetch() { # number out.p12
  local n="$1" secret b64
  if (( n == 1 )); then secret="${PKI_ENROLLMENT_CA_SECRET:-}"; else secret="$(signing_secret_name "${n}")"; fi
  b64="$(aws secretsmanager get-secret-value --secret-id "${secret}" --query SecretBinary --output text 2> /dev/null)" || b64=""
  [[ -n "${b64}" && "${b64}" != "None" ]] || return 1
  ( umask 077; echo "${b64}" | base64 -d > "$2" )
}
# Stores generation N (a p12 built by signing_keystore_build) as a secret. The secret is created if it does not
# exist; an existing one with other content is an error. It does not change what TAK Server signs with.
signing_store() { # number p12
  local n="$1" p12="$2" name back
  (( n >= 2 && n <= 99 )) || { log "ERROR: Enrollment CA number ${n} cannot be stored as a secret (2 to 99)"; return 1; }
  name="$(signing_secret_name "${n}")"
  if aws secretsmanager describe-secret --secret-id "${name}" > /dev/null 2>&1; then
    back="$(aws secretsmanager get-secret-value --secret-id "${name}" --query SecretBinary --output text 2> /dev/null)" || back=""
    if [[ "${back}" == "$(base64 -w0 "${p12}")" ]]; then
      log "the secret ${name} already holds this keystore"
    else
      log "ERROR: the secret ${name} exists with another keystore; not overwriting it"
      return 1
    fi
  else
    aws secretsmanager create-secret --name "${name}" --description "Enrollment CA ${n} keystore (key and chain), written by pki-rotate.sh" \
      --secret-binary "fileb://${p12}" > /dev/null || { log "ERROR: could not create the secret ${name}"; return 1; }
    # a new secret may not be readable for a moment (found on the dev-test stack: the first read after create-secret failed)
    local try
    for try in 1 2 3 4 5; do
      back="$(aws secretsmanager get-secret-value --secret-id "${name}" --query SecretBinary --output text 2> /dev/null)" || back=""
      [[ "${back}" == "$(base64 -w0 "${p12}")" ]] && break
      sleep "${PKI_ROTATE_RETRY_DELAY:-2}"
    done
    [[ "${back}" == "$(base64 -w0 "${p12}")" ]] || { log "ERROR: the secret ${name} does not read back as written (it exists now: the next run continues with it)"; return 1; }
  fi
  # the highest number ever used: a secret that is deleted keeps its name for the recovery window, so a number is never reused
  trust_state_set --argjson n "${n}" '.enrollmentHighest = ([(.enrollmentHighest // 0), $n] | max)' || return 1
}
# Makes generation N (stored) the current one: pki-state.json and this node's tmpfs. A node that starts later restores
# the current secret (pki-bootstrap.sh); the other nodes get it at their restart.
signing_activate() { # number p12
  local n="$1" p12="$2" name
  name="$(signing_secret_name "${n}")"
  ( umask 077; mkdir -p "${TMPFS_DIR}"; chmod 700 "${TMPFS_DIR}"; cp "${p12}" "${TMPFS_DIR}/intermediate-ca-signing.p12.new" && mv -f "${TMPFS_DIR}/intermediate-ca-signing.p12.new" "${TMPFS_DIR}/intermediate-ca-signing.p12" ) \
    || { log "ERROR: cannot write the signing keystore into ${TMPFS_DIR}"; return 1; }
  ( umask 077; rm -f "${TMPFS_DIR}/intermediate-ca-signing.jks"; jks_from_p12 "${TMPFS_DIR}/intermediate-ca-signing.p12" "${TMPFS_DIR}/intermediate-ca-signing.jks" "${SIGNING_ALIAS}" ) || return 1
  chmod 644 "${TMPFS_DIR}/intermediate-ca-signing.jks"
  link_signing_keystore
  trust_state_set --arg s "${name}" --argjson n "${n}" '.enrollmentSecret = $s | .numbers.enrollment = $n' || return 1
  log "Enrollment CA ${n}: the secret ${name} is the current signing keystore (TAK Server loads it at its next start)"
}
signing_install() { # number p12
  signing_store "$1" "$2" && signing_activate "$1" "$2"
}
# The key of a generation that is not in use any more is destroyed (the retire step of a rotation, #135).
#  N >= 2   the secret is deleted with a recovery window of 30 days (the task role may delete these secrets only with a
#           window of 30 days or more: a mistake can be undone for a month)
#  N = 1    the secret of the stack is a CDK resource and stays; its value is overwritten twice with a text, so that the
#           current and the previous version no longer hold the key. The first version, now without a staging label, is
#           deprecated: Secrets Manager removes it, and only its version ID reads it.
# Refuses the current generation and one that the trust manifest still lists. Safe to run again.
SIGNING_RECOVERY_DAYS=30
signing_destroy() { # number
  local n="$1" alias secret tomb i
  alias="$(printf 'enrollment-ca-%02d' "${n}")"
  [[ "${n}" =~ ^[0-9]+$ ]] || { log "ERROR: invalid Enrollment CA number '${n}'"; return 1; }
  [[ "$(jq -r '.numbers.enrollment' "${STATE_FILE}")" != "${n}" ]] || { log "ERROR: Enrollment CA ${n} is the current one: not destroying its key"; return 1; }
  [[ "$(jq -r --arg a "${alias}" '[.trust.entries[]? | select(.alias == $a)] | length' "${STATE_FILE}")" == "0" ]] \
    || { log "ERROR: ${alias} is still in the trust manifest: not destroying its key"; return 1; }
  if (( n == 1 )); then
    secret="${PKI_ENROLLMENT_CA_SECRET:-}"
    [[ -n "${secret}" ]] || { log "ERROR: PKI_ENROLLMENT_CA_SECRET is not set"; return 1; }
    [[ "$(jq -r '.enrollmentSecret // empty' "${STATE_FILE}")" != "${secret}" ]] || { log "ERROR: ${secret} is the current signing secret"; return 1; }
    tomb="$(mktemp "${TMPFS_DIR}/tomb.XXXXXX")" || return 1
    for i in 1 2; do
      printf 'The key of Enrollment CA 01 was destroyed on %s by pki-rotate.sh (%s of 2).\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${i}" > "${tomb}"
      aws secretsmanager put-secret-value --secret-id "${secret}" --secret-binary "fileb://${tomb}" > /dev/null \
        || { log "ERROR: could not overwrite the secret ${secret}"; find "${tomb}" -delete; return 1; }
    done
    find "${tomb}" -delete
    log "the key of Enrollment CA 01 is destroyed (the secret ${secret} was overwritten twice)"
    return 0
  fi
  secret="$(signing_secret_name "${n}")"
  local deleted
  if ! deleted="$(aws secretsmanager describe-secret --secret-id "${secret}" --query DeletedDate --output text 2> /dev/null)"; then
    log "the secret ${secret} does not exist"
    return 0
  fi
  if [[ -n "${deleted}" && "${deleted}" != "None" ]]; then
    log "the secret ${secret} is scheduled for deletion already"
    return 0
  fi
  aws secretsmanager delete-secret --secret-id "${secret}" --recovery-window-in-days "${SIGNING_RECOVERY_DAYS}" > /dev/null \
    || { log "ERROR: could not delete the secret ${secret}"; return 1; }
  log "the secret ${secret} is deleted (recoverable for ${SIGNING_RECOVERY_DAYS} days)"
}
