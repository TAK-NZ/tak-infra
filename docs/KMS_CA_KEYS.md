# Root CA and Intermediate CA keys in AWS KMS

Tracked in [#136](https://github.com/TAK-NZ/tak-infra/issues/136), part of the certificate rotation epic [#128](https://github.com/TAK-NZ/tak-infra/issues/128). The target PKI is described in [#171](https://github.com/TAK-NZ/tak-infra/issues/171).

New stacks keep the private keys of the Root CA (R) and the Intermediate CA (S) in AWS KMS. They never exist as files on EFS, in container memory or in Secrets Manager. The Enrollment Signing CA (Cl) is not in KMS: TAK Server signs client certificates in-process from a keystore.

This page covers the keys, how the container signs with them, and how to operate them. On a new stack the first boot builds the PKI with these keys (`pki-bootstrap.sh`, [#189](https://github.com/TAK-NZ/tak-infra/issues/189), see below). Renewal and rotation come later ([#131](https://github.com/TAK-NZ/tak-infra/issues/131), [#132](https://github.com/TAK-NZ/tak-infra/issues/132), [#135](https://github.com/TAK-NZ/tak-infra/issues/135), [#169](https://github.com/TAK-NZ/tak-infra/issues/169), [#171](https://github.com/TAK-NZ/tak-infra/issues/171), [#172](https://github.com/TAK-NZ/tak-infra/issues/172)).

## Turning it on

Off by default. A stack that does not set it is unchanged.

```json
"pki": {
  "kmsCa": {
    "enabled": true,
    "environmentLabel": "Try",
    "alertEmail": "pki-alerts@example.org"
  }
}
```

or on the command line: `--context pkiKmsCaEnabled=true --context pkiEnvironmentLabel=Try`. See [PARAMETERS.md](PARAMETERS.md#kms-ca-keys).

## What the stack creates

| Resource | Details |
|---|---|
| One KMS key per Root CA and Intermediate CA generation | RSA-4096, `SIGN_VERIFY`, alias `alias/tak-nz-<env>-root-ca-01` and `alias/tak-nz-<env>-intermediate-ca-01`. `RETAIN`: CloudFormation never deletes them |
| Key policy | The account root has management actions only (no `kms:Sign`). The TAK Server task role may `kms:Sign`, `kms:GetPublicKey` and `kms:DescribeKey`. Everyone else, including administrators and the account root, is denied `kms:Sign` |
| SNS topic and EventBridge rule | An alert on every `kms:Sign` that uses a Root CA key. Optional email subscription |
| Container variables | `PKI_ENV_LABEL`, `PKI_KMS_CA_KEYS` (`root-ca-01=<key id>,intermediate-ca-01=<key id>`), `PKI_KMS_REGION` |
| Stack outputs | `RootCa01KeyId`, `IntermediateCa01KeyId`, ... |

KMS never exports the private key of an asymmetric key, so the key policy has no export statement.

The task role is the only signer. The Root CA and Intermediate CA steps run in the same task, so IAM cannot allow Root CA signing for some steps and not for others: the alert on every Root CA signature covers that.

### Root CA signing alert needs a CloudTrail trail

`kms:Sign` is a **read-only management event**. EventBridge only sees it when the account has a CloudTrail trail that logs management events (read and write) in the Region of the stack, and the rule has state `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS` (the construct sets this). This stack does not create the trail: BaseInfra does (setting `cloudTrail.enabled`, default `true`, [base-infra#101](https://github.com/TAK-NZ/base-infra/issues/101)). An account that already has a trail that logs read events in this Region (for example 814704514736 and 453572736517) deploys BaseInfra with `--context createCloudTrail=false`. Check with `aws cloudtrail get-event-selectors --trail-name <trail>` that `ReadWriteType` is `All`. Without such a trail the keys and the signing still work, but no alert is sent. Every call is also visible in CloudTrail event history within seconds.

## Names

Defined in #171. The number identifies a key, not a certificate.

| | Example |
|---|---|
| CN (display name, with `O=TAK.NZ`) | `TAK.NZ Try Root CA 01`, `TAK.NZ Try Intermediate CA 01` |
| KMS alias | `alias/tak-nz-try-root-ca-01` |
| PKCS#11 token label and key label | `root-ca-01`, `intermediate-ca-01` |

To start a rotation, add the next number (`rootCaNumbers: [1, 2]` or `intermediateCaNumbers: [1, 2]`) and deploy. The new key gets the next name; the old key stays.

## Signing in the container

`/opt/tak/scripts/kms-ca.sh` signs with OpenSSL through the `pkcs11` engine (libp11) and the [`aws-kms-pkcs11`](https://github.com/JackOfMostTrades/aws-kms-pkcs11) module, which calls `kms:Sign` with the task role. Both are installed in the TAK Server image (pinned release, checksum checked at build time). Unlike TAK's `makeCert.sh`, which always signs with `ca.pem` and `ca-do-not-share.key`, every command names the signing key.

| Command | Purpose |
|---|---|
| `kms-ca.sh config` | Write the module config from `PKI_KMS_CA_KEYS`. The other commands do this themselves |
| `kms-ca.sh csr <label> <out.csr>` | CSR for a KMS key, subject from the naming rules |
| `kms-ca.sh root-self-sign <root-label> <out.pem> <days>` | Self-signed Root CA certificate (pathlen 3) |
| `kms-ca.sh issue-ca <issuer-label> <issuer.pem> <in.csr> <out.pem> <days> [pathlen]` | CA certificate: root issues an Intermediate CA (pathlen 2), intermediate issues an Enrollment Signing CA (pathlen 0). Pass `[pathlen]` 1 for a bridged Intermediate CA certificate (#172). Signing the CSR of an existing key with another root is the cross-certification of #169 |
| `kms-ca.sh sign <issuer-label> <issuer.pem> <in.csr> <out.pem> <days> <ext-section> <ext-file>` | Server or client certificate, same `-extensions`/`-extfile` handling as `makeCert.sh` |
| `kms-ca.sh crl <label> <cert.pem> <out.crl> <days>` | CRL signed by a KMS key (`makeCert.sh` makes one for every CA it creates) |

The path length defaults leave room for the Intermediate CA bridge of #172 (`R -> S_old -> S_new(A) -> Cl -> client`): Root CA 3, Intermediate CA 2, bridged Intermediate CA 1, Enrollment CA 0. With smaller values a strict validator rejects client certs issued below a bridged certificate (`path length constraint exceeded`; found while testing #133).

Every command checks its result against the issuer certificate and deletes the output if the KMS key is not the key of that certificate.

Notes from the #134 spike:

- `openssl x509 -req` does not copy CSR extensions, so an extension file is always needed.
- Signing takes about 1.2 s per `openssl` process (module start-up fetches the public key of every configured key). The account quota is 1000 RSA operations per second.
- The module config lists only the keys in `PKI_KMS_CA_KEYS`.

## First boot of a new stack (`pki-bootstrap.sh`)

`start-tak.sh` runs `/opt/tak/scripts/pki-bootstrap.sh` before it looks at the TAK Server certificate scripts. With `pki.kmsCa` enabled and no PKI on the EFS yet it builds, in this order:

| Step | Result |
|---|---|
| Root CA 01 | self-signed in KMS, 20 years, pathlen 3 |
| Intermediate CA 01 | issued by Root CA 01 in KMS, 10 years, pathlen 2 |
| Enrollment CA 01 | software key, issued by Intermediate CA 01, 3 years, pathlen 0 |
| Server certificate | CN `<servicename>.<zone>`, SAN `takserver`, `<servicename>.<zone>`, `<hostname>.<zone>`, issued by Intermediate CA 01, 1 year |
| Admin certificate | issued by Enrollment CA 01, 1 year |

Names follow the rules above (`TAK.NZ <Env> <Tier> NN`); the host names come from `takserver.servicename`, `takserver.hostname` and the hosted zone, never from a literal. Every CA certificate has a key-id based Authority Key Identifier.

Files in `/opt/tak/certs/files`, with the names TAK Server and the other scripts already use: `takserver.jks/.p12/.pem/.key`, `admin.p12/.pem/.key`, `truststore-intermediate-ca.jks/.p12`, `fed-truststore.jks`, `ca.pem` (the issuing Intermediate CA), `root-ca.pem`, `intermediate-ca.pem`, `enrollment-ca.pem`, `pki-state.json` and, new, `truststore-phone.jks/.p12`.

- **Server truststore** holds Root CA, Intermediate CA and the Enrollment CA: TAK Server must trust the issuer of every client cert, because ATAK sends only its leaf cert (#133).
- **Phone truststore** (`truststore-phone.p12`, use it for data packages) holds only Intermediate CA and Root CA. A phone does not need the Enrollment CA, and keeping it out of phone stores avoids the known limit in #171. `truststore-root.p12` is not created: a phone with only the root cannot validate the server cert (#170).
- **The Enrollment CA key** is generated in tmpfs and written only to the secret `<stack>/...Enrollment-CA` (a retained Secrets Manager secret, PKCS#12 with the key and the chain). The file TAK Server reads, `intermediate-ca-signing.jks`, is a symlink into tmpfs, restored from the secret at every start. No CA key is on the EFS: there is no `root-ca-do-not-share.key` and no `ca-do-not-share.key`.
- **Admin cert files:** `admin.p12` for the services that call the TAK API, and `admin.pem` / `admin.key`, which the container health check reads (#189 finding from #133).
- **Keystore password** stays `atakatak`, the value `CoreConfig.xml` uses for every keystore. It protects the JKS and PKCS#12 files only: R and S are in KMS and the Enrollment CA key is in Secrets Manager.
- **PKCS#12 profile** of the user-facing p12 files (`takserver.p12`, `admin.p12`): `P12_PROFILE`, `compat3des` by default (3DES, SHA-1 MAC; plain `-legacy` is never used).
- **Not touched:** a stack that already has a PKI from the old scripts (`ca.pem` without `pki-state.json`) keeps it. There is no migration.
- **Fails closed:** with `pki-state.json` present, a missing file or an unreadable secret stops the start instead of generating a second PKI. A failed write to Secrets Manager installs nothing, so the next start can bootstrap again.
- **Several nodes:** `pki-bootstrap.sh` runs under the cluster lock (`docs/CLUSTER_LOCK.md`). On a fresh stack one node builds the PKI, the others wait and restore it. The decision between build, restore and "old flow" is made inside the lock.
- **Not in this step:** renewal and rotation, the CRLs and revocation scripts of the old flow.

`pki-state.json` records the names, the p12 profile and the expiry dates, for the rotation orchestrator (#171).

## Server certificate rotation (`server-cert-rotate.sh`)
The TAK Server certificate (`takserver.pem`, `.key`, `.p12`, `.jks`) is rotated automatically on stacks with the first-boot PKI ([#131](https://github.com/TAK-NZ/tak-infra/issues/131)). A loop in `start-tak.sh` runs `server-cert-rotate.sh check` 15 minutes after the start and then every 24 hours; it rotates when the certificate has `pki.kmsCa.validity.serverCertRenewDays` (default 60) or fewer days left. `server-cert-rotate.sh rotate` rotates at once. Stacks with the PKI of the TAK Server scripts are left alone.
Rotation runs under the cluster lock `server-cert-rotation`, so one node does it (`docs/CLUSTER_LOCK.md`):
1. A new key and CSR for the names in `PKI_SERVER_NAMES` (so a changed host name or service name is picked up), signed by Intermediate CA S in KMS. Validity `serverCertDays` (default 365).
2. Everything is built and checked in tmpfs first: chain to R and S, key against certificate, CN and SAN, days left, and that the new `takserver.jks` and `takserver.p12` open with the keystore password and hold the new certificate. A failed check changes nothing on the EFS.
3. Swap: a marker file, a `.prev` copy of each of the four files, one atomic rename per file, the same checks on the installed files. A failure restores the `.prev` copies. A marker found at the next run means the swap was interrupted (task stopped): the `.prev` copies are restored then, and nothing is rotated until that works.
4. The state file gets the new `notAfter.server`, `TakServerCertRotated` is emitted, and an ECS rolling deployment makes every node load the new keystore (TAK Server reads it at start). Phones are not touched: they do not pin the leaf, and S and R are unchanged.
Every failure emits `TakServerCertRotationFailed` (alert). If only the deployment cannot be started, the new certificate stays installed and the failure metric tells you that TAK Server loads it at its next restart. `takserver.pem.prev` and the other `.prev` files hold the last previous set (the key and p12 are mode 600); the next rotation overwrites them. The renewal threshold must be smaller than the validity (checked at synth and at run time), or each new certificate would be rotated again at once.
Not covered: the admin certificate (#132), and a server certificate signed with a different Intermediate CA than the one in the state file (#172).
## Admin certificate rotation (`admin-cert-rotate.sh`)
The admin client certificate (`admin.pem`, `admin.key`, `admin.p12`) is rotated automatically on stacks with the first-boot PKI ([#132](https://github.com/TAK-NZ/tak-infra/issues/132)). The same daily loop as for the server certificate runs `admin-cert-rotate.sh check`; it rotates at `pki.kmsCa.validity.adminCertRenewDays` (default 60) or fewer days left. `admin-cert-rotate.sh rotate` rotates at once. The admin certificate is used by the container health check (`admin.pem` and `admin.key`), by the admin elevation at start (`certmod -A admin.pem`) and, through the secret `<stack>/TAK-Server/Admin-Cert`, by TAKTeamManager, CloudTAK and other services.
Under the cluster lock `admin-cert-rotation`:
1. A new key for `CN=admin`, signed by the Enrollment CA (its key is the software key that `start-tak.sh` restores from Secrets Manager into tmpfs, so it never touches the EFS). Validity `adminCertDays` (default 365), capped to what the Enrollment CA has left; if that is not more than the renewal threshold the rotation stops and says to rotate the Enrollment CA first (#135).
2. Built and checked in tmpfs: chain to R, S and Cl, key against certificate, CN, and that `admin.p12` (compat3des or aes256, as configured) and `admin.key` open with the keystore password.
3. **Registered before any file changes**: `UserManager.jar certmod -A` for the new certificate, `certmod -s` must list it as `ROLE_ADMIN` with the new fingerprint, and one call to the TAK Server API (`/Marti/api/certadmin/cert`) with the new certificate must answer 200. A failure here changes nothing on the EFS and registers the current certificate again.
4. Swap of the three files: marker, `.prev` copies, one atomic rename per file, the same checks on the installed files. A failure restores the `.prev` copies and registers the old certificate again; an interrupted swap is restored at the next run.
5. The secret is updated with the file hash as request token (the same token `start-tak.sh` uses, so the next start sees "unchanged"). If that fails the new files stay, `AdminCertRotationFailed` is emitted, `adminSecretPending` is set in `pki-state.json`, and the next daily check tries the secret again.
6. `pki-state.json` gets the new `notAfter.admin`, `AdminCertRotated` is emitted. **No restart**: the health check reads the files on every call, and TAK Server looks the user up when a request arrives.
The `.prev` copies hold the previous admin key. They are deleted `pki.kmsCa.validity.adminCertGraceDays` (default 7) after the rotation. That is the window for a rollback and for the services to pick up the new secret (TAKTeamManager refreshes it every 24 hours).
**What this does not do: revoke the old admin certificate.** TAK Server finds the admin user by the CN `admin` of any certificate that its truststore accepts (checked on the dev-test stack: a new certificate with CN `admin` from the same CA was accepted as administrator before it was registered, and the old one still works after `certmod -A` of the new one; `certmod -A` only replaces the stored fingerprint). No CRL is configured, and the certadmin revoke API only knows certificates that TAK Server issued itself, which the admin certificate is not. The old certificate therefore works until its own `notAfter`, or until its issuer is removed from the truststore (an Enrollment CA rotation, #135). If an admin key is compromised, rotate the Enrollment CA, do not wait for this script. `certmod -D` is not an option: it deletes the user `admin` and so every admin certificate.
## Metrics and alarms (`cert-metrics.sh`)

One helper for all certificate work ([#129](https://github.com/TAK-NZ/tak-infra/issues/129)). Metrics go to the CloudWatch namespace `TAK/Certificates` with the dimension `Stack=<stack name>`; the alarms (created with `pki.kmsCa`) fire at a value of 1 and treat missing data as fine, so an alarm whose emitter is not built yet stays in OK.

From a script: `/opt/tak/scripts/cert-metrics.sh emit <MetricName> [value] [Dimension=Value ...]`, or `source` it with `CERT_METRICS_SOURCE_ONLY=1` and call `emit_metric`. It refuses names that are not in the table (a typo would feed no alarm), validates the dimensions, and never fails the caller when CloudWatch cannot be reached.

| Metric | Alarm | Severity | Emitted by |
|---|---|---|---|
| `RootCAExpiryWarning` | daily maximum >= 1 | alert | `cert-metrics.sh check-expiry`: Root CA expires in 730 days or less |
| `IntermediateCAExpiryWarning` | daily maximum >= 1 | alert | `check-expiry`: Intermediate CA expires in 1275 days (2W + 1 year) or less |
| `CAExpired` | daily maximum >= 1 | critical | `check-expiry`: Root, Intermediate or Enrollment CA has expired |
| `RootCASigned` | every `kms:Sign` with a Root CA key | alert | the EventBridge rule of #136 (CloudTrail), not a metric |
| `CertbotRenewalFailure` | 5 minute sum >= 1 | alert | `certbot-renew.sh` and `letsencrypt-request-cert.sh` (#130, `docs/LETSENCRYPT.md`) |
| `TakServerCertRotated` / `TakServerCertRotationFailed` | 5 minute sum >= 1 | info / alert | `server-cert-rotate.sh` (#131, below) |
| `AdminCertRotated` / `AdminCertRotationFailed` | 5 minute sum >= 1 | info / alert | `admin-cert-rotate.sh` (#132, below) |
| `SigningCARotated` | 5 minute sum >= 1 | info | #135 |
| `IntermediateCARotationPhase` (`Phase=bridge`, `cut`, `retire`) | 5 minute sum >= 1, one alarm per phase | info | #172 |
| `RootCARotated` | 5 minute sum >= 1 | info | #169 |
| `RotationCoverageStragglers` | 5 minute sum >= 1 | alert | #171 |

`check-expiry` reads `root-ca.pem`, `intermediate-ca.pem` and `enrollment-ca.pem` in the files directory and emits 0 or 1 for the three metrics every time, so the alarms return to OK and "no data" is not mistaken for "fine". It does nothing on a stack without `pki-state.json` (a PKI from the old scripts). `start-tak.sh` runs it 60 seconds after the start and then every 24 hours. The thresholds are `PKI_ROOT_WARN_DAYS` (730) and `PKI_INTERMEDIATE_WARN_DAYS` (1275).

Three SNS topics by severity: alert, critical and info. `pki.kmsCa.alertEmail` subscribes the alert and critical topics, `pki.kmsCa.infoEmail` the info topic; without an address the topics exist and you subscribe to them yourself. The Root CA signing alert of #136 publishes to the alert topic.

## Retiring a key

When a rotation is complete (#169, #172), schedule the old key for deletion with the full window:

```bash
aws kms schedule-key-deletion --key-id alias/tak-nz-try-intermediate-ca-01 --pending-window-in-days 30
```

The task role has no permission to do this. Afterwards remove the number from `rootCaNumbers` / `intermediateCaNumbers`; CloudFormation retains the key either way.

## Tests

- `npx jest test/unit/constructs/ca-kms-keys.test.ts test/unit/utils/pki-names.test.ts`: key spec, policy, alias names, alert rule.
- `test/KmsCa/test-cert-metrics.sh`: the metric helper (refused input, dimensions, CloudWatch down) and the expiry check (thresholds, expired CA, unreadable certificate) with a stub `aws`. Runs in CI.
- `test/KmsCa/test-admin-cert-rotate.sh`: the admin rotation end to end (not due, due, register before swap, the order of the calls, grace period, forced rotation, a TAK Server that refuses the new certificate, a failed registration, a missing signing keystore, an install failure and rollback, an interrupted swap, a secret that cannot be updated and the retry, the Enrollment CA validity cap, two nodes at once, a held lock, p12 profiles) with SoftHSM and stubs for `aws`, `java` (UserManager) and `curl` (the API). Runs in CI.
- `test/KmsCa/test-server-cert-rotate.sh`: the rotation end to end (not due, due, forced, a rejected new certificate, an install failure and rollback, an interrupted swap, a deployment that cannot start, two nodes at once, a held lock, changed names, p12 profiles) with SoftHSM and stubs for `aws`. Runs in CI. `test/KmsCa/pki-harness.sh` is the set-up it shares with the bootstrap test.
- `test/KmsCa/test-cluster-lock.sh`: the cluster lock (`docs/CLUSTER_LOCK.md`). Runs in CI.
- `test/KmsCa/test-pki-bootstrap.sh`: the first-boot PKI end to end (names, constraints, chains, keystores, truststores, no CA key on the EFS, restore on a later start, three nodes at once, fail-closed cases, validities, p12 profiles) with SoftHSM and a stub `aws`. Runs in CI.
- `test/KmsCa/test-kms-ca.sh`: the wrapper end to end with SoftHSM standing in for KMS (root, intermediate, cross-certificate, enrollment CA, server cert, CRL, wrong-key and bad-input cases). Needs `softhsm2 opensc libengine-pkcs11-openssl jq`. It runs in CI.
- Not covered by automated tests: the real KMS call and a task role in ECS. The module was validated against KMS in #134.
