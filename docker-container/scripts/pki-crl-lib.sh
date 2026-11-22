#!/bin/bash
# pki-crl-lib.sh - certificate revocation lists for the Enrollment CAs (#204).
# Sourced by pki-bootstrap.sh, revoke-cert.sh and the rotation scripts. Needs log, KS_PASS, FILES_DIR, STATE_FILE,
# TMPFS_DIR and, from pki-trust-lib.sh, the trust manifest and signing_secret_name.
#
# Why. TAK Server finds the administrator by the CN of any certificate that its truststore accepts, so the old
# admin certificate of a rotation (#132) keeps working until it expires, and the revoke API of TAK Server knows only
# certificates that it issued itself. A CRL signed by the Enrollment CA revokes one certificate by serial: the others
# of the same CN keep working (checked on the dev-test stack, #204: refused on 8089 with "certificate revoked" and on
# 8443 without a connection; an empty CRL changes nothing; TAK Server ignores `nextUpdate`).
#
# What. One CRL per Enrollment CA generation: ${FILES_DIR}/crl/<alias>.crl (PEM, public), with the `openssl ca`
# database in ${FILES_DIR}/crl/db/<alias>/ (index, serial numbers; no key). createCoreConfig.sh puts a <crl> element
# for every *.crl into CoreConfig.xml. **TAK Server reads the files only at start**, so a revocation is in force after
# the next start: crl_revoke_* return 10, which tells the caller to start a rolling deployment (4 to 9 minutes).
# **Found on the dev-test stack (#135): the API of TAK Server (port 8443) honours only the first <crl> element**; a
# client certificate from an Enrollment CA with no CRL there is refused ("certificate unknown": revocation status
# undetermined), while the messaging service (8089) uses every element. With a second Enrollment CA that refuses the
# admin certificate of the new CA. So `crl/00-all.crl`, a file that holds the CRL of every Enrollment CA one after the
# other (PEM), is kept up to date, and createCoreConfig.sh lists it first (a glob sorts it before enrollment-ca-NN.crl).
# The CRL is signed with the key of the CA that issued the certificates: the current generation from tmpfs, an
# older one from its secret. The key exists in a temporary file in tmpfs for the time of the signing only.
CRL_DIR="${FILES_DIR}/crl"
CRL_DAYS="${PKI_CRL_DAYS:-365}"
CRL_REASONS="unspecified keyCompromise CACompromise affiliationChanged superseded cessationOfOperation certificateHold"
crl_file() { echo "${CRL_DIR}/$1.crl"; }
CRL_ALL_FILE="${CRL_DIR}/00-all.crl"
# The combined CRL file: every Enrollment CA's CRL in one file (see above). 0 unchanged, 10 changed (TAK Server reads
# it at its next start), 1 failed. Called after every change of a CRL, and at start.
crl_combine() {
  local f tmp files=()
  for f in "${CRL_DIR}"/enrollment-ca-[0-9][0-9].crl; do [[ -f "${f}" ]] && files+=("${f}"); done
  if (( ${#files[@]} == 0 )); then
    [[ -e "${CRL_ALL_FILE}" ]] || return 0
    find "${CRL_ALL_FILE}" -delete 2> /dev/null; return 10
  fi
  tmp="${CRL_ALL_FILE}.new"
  cat "${files[@]}" > "${tmp}" || { log "crl: cannot write ${tmp}"; return 1; }
  if [[ -f "${CRL_ALL_FILE}" ]] && cmp -s "${tmp}" "${CRL_ALL_FILE}"; then find "${tmp}" -delete 2> /dev/null; return 0; fi
  chmod 644 "${tmp}" && mv -f "${tmp}" "${CRL_ALL_FILE}" || { log "crl: cannot write ${CRL_ALL_FILE}"; return 1; }
  return 10
}
crl_prepare() { mkdir -p "${TMPFS_DIR}" && chmod 700 "${TMPFS_DIR}"; }
crl_alias_ok() { [[ "$1" =~ ^enrollment-ca-[0-9]{2}$ ]]; }
crl_number_of() { echo $(( 10#${1##*-} )); }
# the CA certificate of an alias: the file of the trust manifest
crl_ca_cert() {
  local f
  f="$(jq -r --arg a "$1" '.trust.entries[]? | select(.alias == $a) | .file' "${STATE_FILE}" 2> /dev/null | head -1)"
  [[ -n "${f}" ]] && echo "${FILES_DIR}/${f}"
}
# every Enrollment CA of the manifest
crl_aliases() { jq -r '.trust.entries[]? | select(.alias | test("^enrollment-ca-[0-9]{2}$")) | .alias' "${STATE_FILE}" 2> /dev/null; }

# openssl ca configuration for one CA. root is the directory with <alias>.crl and db/<alias>.
crl_write_config() { # root alias ca.pem key out
  local db="$1/db/$2"
  cat > "$5" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
database = ${db}/index.txt
new_certs_dir = ${db}
serial = ${db}/serial
crlnumber = ${db}/crlnumber
certificate = $3
private_key = $4
default_md = sha256
default_crl_days = ${CRL_DAYS}
unique_subject = no
policy = policy_any
crl_extensions = crl_ext
[ policy_any ]
commonName = supplied
[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF
}
# A new CRL database with an empty list, signed with the given key. root is a directory (the files directory's crl
# directory, or a work directory at the first boot).
crl_create() { # root alias ca.pem key
  local root="$1" alias="$2" cnf db
  db="${root}/db/${alias}"
  mkdir -p "${db}" || return 1
  [[ -f "${db}/index.txt" ]] || : > "${db}/index.txt"
  [[ -f "${db}/index.txt.attr" ]] || echo "unique_subject = no" > "${db}/index.txt.attr"
  [[ -f "${db}/serial" ]] || echo 1000 > "${db}/serial"
  [[ -f "${db}/crlnumber" ]] || echo 01 > "${db}/crlnumber"
  cnf="$(mktemp "${TMPFS_DIR}/crl-cnf.XXXXXX")" || return 1
  crl_write_config "${root}" "${alias}" "$3" "$4" "${cnf}"
  openssl ca -config "${cnf}" -gencrl -crldays "${CRL_DAYS}" -out "${root}/${alias}.crl.new" > /dev/null 2>&1 \
    && openssl crl -in "${root}/${alias}.crl.new" -CAfile "$3" -noout -verify > /dev/null 2>&1 \
    && chmod 644 "${root}/${alias}.crl.new" && mv -f "${root}/${alias}.crl.new" "${root}/${alias}.crl"
  local rc=$?
  find "${cnf}" -delete 2> /dev/null
  (( rc == 0 )) || log "crl: could not write the CRL of ${alias}"
  return "${rc}"
}

# The key of an Enrollment CA generation, as a PEM in a file the caller deletes: the current generation is in tmpfs, an
# older one in its secret (generation 1 is the secret of the stack).
crl_get_key() { # alias out
  local alias="$1" n p12 secret b64 current
  n="$(crl_number_of "${alias}")"
  current="$(jq -r '.numbers.enrollment' "${STATE_FILE}")"
  p12="$(mktemp "${TMPFS_DIR}/crl-p12.XXXXXX")" || return 1
  if (( n == current )) && [[ -s "${TMPFS_DIR}/intermediate-ca-signing.p12" ]]; then
    cp "${TMPFS_DIR}/intermediate-ca-signing.p12" "${p12}"
  else
    if (( n == 1 )); then secret="${PKI_ENROLLMENT_CA_SECRET:-}"; else secret="$(signing_secret_name "${n}")"; fi
    b64="$(aws secretsmanager get-secret-value --secret-id "${secret}" --query SecretBinary --output text 2> /dev/null)" || b64=""
    if [[ -z "${b64}" || "${b64}" == "None" ]]; then
      find "${p12}" -delete; log "crl: the key of ${alias} is not available (no secret ${secret})"; return 1
    fi
    echo "${b64}" | base64 -d > "${p12}"
  fi
  openssl pkcs12 -in "${p12}" -passin "pass:${KS_PASS}" -nodes -nocerts -out "$2" 2> /dev/null
  local rc=$?
  find "${p12}" -delete
  (( rc == 0 )) || log "crl: cannot read the key of ${alias}"
  return "${rc}"
}

# Makes sure a CRL exists for an alias; creates an empty one with the key of the CA. 0 nothing to do, 10 created.
crl_ensure() { # alias
  local alias="$1" ca key rc=0
  crl_alias_ok "${alias}" || { log "crl: invalid alias '${alias}'"; return 1; }
  [[ -s "$(crl_file "${alias}")" && -f "${CRL_DIR}/db/${alias}/index.txt" ]] && return 0
  crl_prepare || return 1
  ca="$(crl_ca_cert "${alias}")"
  [[ -n "${ca}" && -s "${ca}" ]] || { log "crl: ${alias} is not in the trust manifest"; return 1; }
  umask 077
  key="$(mktemp "${TMPFS_DIR}/crl-key.XXXXXX")" || return 1
  if crl_get_key "${alias}" "${key}"; then crl_create "${CRL_DIR}" "${alias}" "${ca}" "${key}" || rc=1; else rc=1; fi
  find "${key}" -delete 2> /dev/null
  umask 022
  (( rc == 0 )) || return 1
  crl_combine > /dev/null || true
  chmod -R a+rX "${CRL_DIR}" 2> /dev/null
  log "the CRL of ${alias} was created (empty): CoreConfig.xml gets it at the next start"
  return 10
}
# Revokes a serial: the line in the index, a new signed CRL, the files in place. 0 already revoked, 10 revoked (restart needed).
crl_revoke_serial() { # alias serial(hex) notAfter(date) subject(/O=..) reason
  local alias="$1" serial="${2^^}" notafter="$3" subject="$4" reason="${5:-superseded}" ca key cnf db backup t rc=0 exp
  crl_alias_ok "${alias}" || { log "crl: invalid alias '${alias}'"; return 1; }
  [[ "${serial}" =~ ^[0-9A-F]{1,40}$ ]] || { log "crl: invalid serial '${2}'"; return 1; }
  [[ " ${CRL_REASONS} " == *" ${reason} "* ]] || { log "crl: unknown reason '${reason}' (use ${CRL_REASONS})"; return 1; }
  ca="$(crl_ca_cert "${alias}")"
  [[ -n "${ca}" && -s "${ca}" ]] || { log "crl: ${alias} is not in the trust manifest"; return 1; }
  serial="$(printf '%X' "$((16#${serial}))")"
  (( ${#serial} % 2 )) && serial="0${serial}"
  db="${CRL_DIR}/db/${alias}"
  crl_ensure "${alias}" > /dev/null; [[ -s "$(crl_file "${alias}")" ]] || return 1
  if awk -F'\t' -v s="${serial}" '$1 == "R" && $4 == s {f = 1} END {exit !f}' "${db}/index.txt"; then
    log "crl: serial ${serial} is revoked in the CRL of ${alias} already"
    return 0
  fi
  crl_prepare || return 1
  exp="$(date -u -d "${notafter}" +%y%m%d%H%M%SZ 2> /dev/null)" || { log "crl: cannot read the date '${notafter}'"; return 1; }
  t="$(date -u +%y%m%d%H%M%SZ)"
  umask 077
  backup="$(mktemp -d "${TMPFS_DIR}/crl-backup.XXXXXX")" || return 1
  cp -p "${db}/index.txt" "${db}/crlnumber" "${backup}/"
  [[ -f "$(crl_file "${alias}")" ]] && cp -p "$(crl_file "${alias}")" "${backup}/"
  key="$(mktemp "${TMPFS_DIR}/crl-key.XXXXXX")"
  cnf="$(mktemp "${TMPFS_DIR}/crl-cnf.XXXXXX")"
  if crl_get_key "${alias}" "${key}"; then
    printf 'R\t%s\t%s,%s\t%s\tunknown\t%s\n' "${exp}" "${t}" "${reason}" "${serial}" "${subject}" >> "${db}/index.txt"
    crl_write_config "${CRL_DIR}" "${alias}" "${ca}" "${key}" "${cnf}"
    if openssl ca -config "${cnf}" -gencrl -crldays "${CRL_DAYS}" -out "${CRL_DIR}/${alias}.crl.new" > /dev/null 2>&1 \
       && openssl crl -in "${CRL_DIR}/${alias}.crl.new" -CAfile "${ca}" -noout -verify > /dev/null 2>&1 \
       && openssl crl -in "${CRL_DIR}/${alias}.crl.new" -noout -text | grep -q "Serial Number: ${serial}$"; then
      chmod 644 "${CRL_DIR}/${alias}.crl.new" && mv -f "${CRL_DIR}/${alias}.crl.new" "$(crl_file "${alias}")" || rc=1
    else
      rc=1
    fi
  else
    rc=1
  fi
  if (( rc != 0 )); then
    log "crl: the revocation of ${serial} failed; the previous CRL is kept"
    cp -p "${backup}/index.txt" "${backup}/crlnumber" "${db}/" 2> /dev/null
    find "${CRL_DIR}/${alias}.crl.new" -delete 2> /dev/null
  fi
  find "${key}" "${cnf}" "${backup}" -delete 2> /dev/null
  umask 022
  (( rc == 0 )) || return 1
  crl_combine > /dev/null || [[ $? == 10 ]] || log "WARNING: the combined CRL file could not be written"
  log "revoked serial ${serial} in the CRL of ${alias} (${reason}); it is in force after the next start of TAK Server"
  return 10
}
# Deletes the CRL and its database of a CA that is not trusted any more (the retire step of an Enrollment CA rotation).
# Refuses an alias that the trust manifest still lists. Safe to run again.
crl_retire() { # alias
  local alias="$1"
  crl_alias_ok "${alias}" || { log "crl: invalid alias '${alias}'"; return 1; }
  [[ -z "$(crl_ca_cert "${alias}")" ]] || { log "crl: ${alias} is still in the trust manifest: not deleting its CRL"; return 1; }
  find "${CRL_DIR}/${alias}.crl" "${CRL_DIR}/${alias}.crl.new" "${CRL_DIR}/db/${alias}" -delete 2> /dev/null
  crl_combine > /dev/null || [[ $? == 10 ]] || log "WARNING: the combined CRL file could not be written"
  log "the CRL of ${alias} is deleted: CoreConfig.xml loses it at the next start"
  return 0
}
# Which Enrollment CA issued this certificate? Prints the alias.
crl_alias_of_cert() { # cert.pem
  local a ca
  while IFS= read -r a; do
    ca="$(crl_ca_cert "${a}")"
    [[ -s "${ca}" ]] || continue
    if openssl verify -no_check_time -partial_chain -CAfile "${ca}" "$1" > /dev/null 2>&1; then echo "${a}"; return 0; fi
  done < <(crl_aliases)
  return 1
}
crl_revoke_cert() { # cert.pem [reason]
  local pem="$1" alias serial notafter subject
  openssl x509 -in "${pem}" -noout > /dev/null 2>&1 || { log "crl: ${pem} is not a certificate"; return 1; }
  alias="$(crl_alias_of_cert "${pem}")" || { log "crl: ${pem} was not issued by an Enrollment CA of this stack"; return 1; }
  serial="$(openssl x509 -in "${pem}" -noout -serial | cut -d= -f2)"
  notafter="$(openssl x509 -in "${pem}" -noout -enddate | cut -d= -f2)"
  subject="$(openssl x509 -in "${pem}" -noout -subject -nameopt compat | sed 's/^subject=//')"
  crl_revoke_serial "${alias}" "${serial}" "${notafter}" "${subject}" "${2:-unspecified}"
}
# The CRL of every Enrollment CA exists. 0 nothing to do, 10 a CRL was created.
crl_ensure_all() {
  local a rc=0 r
  while IFS= read -r a; do
    r=0; crl_ensure "${a}" || r=$?
    (( r == 10 )) && rc=10
    (( r == 1 )) && { rc=1; break; }
  done < <(crl_aliases)
  (( rc == 1 )) && return 1
  r=0; crl_combine || r=$?
  (( r == 1 )) && return 1
  (( r == 10 )) && rc=10
  return "${rc}"
}
