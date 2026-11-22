# admin.p12 that OpenSSL 3 can read

## The problem

On a stack with the PKI of the TAK Server scripts (no `pki-state.json`), `makeCert.sh` writes `admin.p12` with plain `-legacy`. The keystore uses 3DES for the key, but the certificates are encrypted with **RC2-40** and the MAC is SHA-1. OpenSSL 3 without the legacy provider cannot read that (`unsupported ... Algorithm (RC2-40-CBC : 0)`), and neither can Node's `tls` `pfx` option. A third-party system that loads the secret failed this way. Readers that bring their own PKCS#12 code (node-forge, p12-pem) are not affected, which is why TAKTeamManager, TAK-Portal and CloudTAK worked.

New stacks with the first-boot PKI (`pki.kmsCa`) write the compat3des profile already (`-legacy -descert`: 3DES, SHA-1 MAC; `docs/KMS_CA_KEYS.md`), so they need nothing.

New stacks with the first-boot PKI also rotate the admin certificate automatically (`docs/KMS_CA_KEYS.md`, #132); every rotated `admin.p12` has the compat3des profile.

## The fix for an existing stack

`/opt/tak/scripts/admin-p12-reexport.sh` (in the image from this change on) exports the same key and certificates again with the compat3des profile.

```bash
admin-p12-reexport.sh --dry-run   # export and check, change nothing
admin-p12-reexport.sh             # replace admin.p12 and update the secret
```

What it does, in order:
1. Opens `admin.p12` with the legacy provider (password `P12_PASSWORD`, default `atakatak`). Exits at once with "nothing to do" if the file is readable without the legacy provider already.
2. Exports again, and checks that the new file opens **without** the legacy provider and holds the same certificates (fingerprints, chain) and the same key.
3. Keeps the old file as `admin.p12.rc2` (once), replaces `admin.p12` by rename (mode 600).
4. Writes the secret `<StackName>/TAK-Server/Admin-Cert` with `put-secret-value` and the file hash as client request token. `start-tak.sh` uploads with the same token at every start, so it then sees "unchanged". The old secret version stays as `AWSPREVIOUS`.

The file is replaced before the secret is written, on purpose: if the secret update fails, the next start uploads the new file. The other order would let the next start upload the old file again. It runs under the cluster lock `admin-p12-reexport` (exit 75 if another node is running it). `admin.pem` and `admin.key` are PEM and are not touched.

To run it on a running task without a new image, copy the script and `cluster-lock.sh` into the container with ECS Exec (gzip and base64 on the command line) and run them from `/tmp`.

## Roll back

```bash
# the file on the EFS
cp -p /opt/tak/certs/files/admin.p12.rc2 /opt/tak/certs/files/admin.p12
# the secret: move AWSCURRENT back to the previous version
aws secretsmanager update-secret-version-stage --secret-id <StackName>/TAK-Server/Admin-Cert --version-stage AWSCURRENT \
  --move-to-version-id <id of the AWSPREVIOUS version> --remove-from-version-id <id of the AWSCURRENT version>
```
Do both, or the next start uploads the file you did not roll back.

## Who reads the secret (checked for #132)

| Consumer | How it reads the p12 | Reads 3DES / SHA-1 |
|---|---|---|
| TAKTeamManager `AdminCredentialLoader` | node-forge 1.4.3 `pkcs12FromAsn1` | yes (tested with the new profile) |
| TAK-Portal `tak.service.js` | p12-pem 1.0.5 (node-forge) | yes (tested) |
| CloudTAK `api/common/config.ts` | `pem.readPkcs12` 1.14.8, which runs `openssl pkcs12` | yes (tested). It reads the RC2-40 file too (`pem` adds `-legacy` on OpenSSL 3), so it was not affected |
| Node `tls` with `pfx` | OpenSSL 3 | yes (tested in #133) |
| `scripts/deviceprofiles/upload-device-profile.sh --p12` | curl | still needs PEM for the RC2 file; works with the new file |

Not changed on purpose: AES-256 is not used. Apple, Android, ATAK, iTAK and WinTAK imports of AES-256 files were tested in #133 for the user-facing p12 files, but the admin p12 is a server credential, and compat3des is what the rest of the stack uses.
