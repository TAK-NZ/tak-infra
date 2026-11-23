# Certificate management

How the certificates of a TAK Server stack are issued and renewed, and what an operator does when. Details of each script are in [KMS_CA_KEYS.md](KMS_CA_KEYS.md). Settings are in [PARAMETERS.md](PARAMETERS.md#kms-ca-keys).

## Two kinds of stack

| | Stack with `pki.kmsCa.enabled` (new stacks) | Stack without it (existing stacks) |
|---|---|---|
| PKI | Built at the first start: Root CA (R) and Intermediate CA (S) keys in AWS KMS, Enrollment CA (Cl) key in Secrets Manager and tmpfs, never on the EFS | Made by the TAK Server scripts (`makeCert.sh`), CA keys on the EFS |
| Renewal and rotation | Automatic, see below | **Manual.** Nothing renews the TAK certificates |
| Let's Encrypt (port 8446) | Automatic | Automatic and cluster-safe (the failure alarm needs `pki.kmsCa`) |

A stack that has the old PKI keeps it, even if `pki.kmsCa` is turned on later: there is no migration of the certificates. To get the new PKI, build a new stack, or reset the PKI of the stack in place (below). Either way every phone enrols again.

## The hierarchy and what rotates when (defaults)

```
Root CA (R, KMS)  ->  Intermediate CA (S, KMS)  ->  Enrollment CA (Cl, secret)  ->  client certificates (phones, admin)
                                  \-> server certificate (TAK Server, ports 8089 and 8443)
```

| Certificate | Valid | Rotated | By |
|---|---|---|---|
| Server certificate, admin certificate | 1 year | 60 days before expiry | `pki-rotate.sh run`, daily |
| Client certificates (phones) | 1 year | when the user enrols again | the user (QR code) |
| Enrollment CA | 3 years | when it is 1 year old | scenario `enrollment` |
| Intermediate CA | 10 years | 1275 days before expiry | scenario `intermediate` |
| Root CA | 20 years | 820 days before expiry | scenario `root` |

`W` = client certificate validity + buffer = 365 + 90 = **455 days**. A phone gets its new trust by enrolling, so each rotation waits W before it removes the old CA: every phone that is used once a year has enrolled again by then.

All of it runs in the TAK Server container, once a day (first run 15 minutes after the start), under a lock on the EFS so that only one node acts. State is in `/opt/tak/certs/files/rotation-state.json` and `pki-state.json`. A step that fails is retried the next day and raises an alarm.

## What the operator does

Run commands in the container: `aws ecs execute-command --cluster TAK-<n>-BaseInfra --task <task> --container TakServer --interactive --command "bash"`, then `/opt/tak/scripts/pki-rotate.sh ...`.

**Routine: nothing.** Look at `pki-rotate.sh plan` now and then: it lists every layer, its expiry, when its rotation starts, and the active rotation.

| When | What to do |
|---|---|
| A CA rotation waits for an approval (`pki-rotate.sh status`, alarm `RotationWaiting`) | Check the list of users in the alert mail, then `pki-rotate.sh approve <scenario> <step>`. By default the steps `cut` (Intermediate CA) and `retire` (all scenarios) need it: they cannot be undone |
| Alarm `RotationCoverageStragglers`, or the mail "N user(s) must enroll again" | Ask the listed users to enrol again (QR code). The rotation goes on by itself when all have. Users listed as *unknown* use a hand-made data package: the check cannot see them, tell them yourself |
| Alarm `RotationSpareKeyMissing` | Add the next number to `pki.kmsCa.rootCaNumbers` or `intermediateCaNumbers` and deploy (creates the KMS key). There is years of time; do it before the next rotation |
| A rotation has finished (log: "is retired") | Schedule the old KMS key for deletion with a 30-day window, by alias (`aws kms schedule-key-deletion --key-id alias/... --pending-window-in-days 30`; the container cannot), **then** remove the old generation from `rootCaNumbers` / `intermediateCaNumbers` and deploy: the alias goes with the number. Old Enrollment CA secrets are deleted by the rotation, with a recovery window of 30 days |
| Info alarm `AdminCertRotated` (new admin certificate) | Restart CloudTAK, see [CloudTAK and TAKTeamManager](#cloudtak-and-takteammanager). TAKTeamManager follows by itself within a day |
| Alarm `RotationStepFailed` | Read the log group `TakServer-takserver` (`PKI:` lines). The step is retried daily; fix the cause |
| `TakServerCertRotationFailed`, `AdminCertRotationFailed` | Same; run `server-cert-rotate.sh rotate` or `admin-cert-rotate.sh rotate` by hand after the fix |
| `CertbotRenewalFailure` | Port 80 to the load balancer and DNS of `ops.<zone>` must work (HTTP-01). Run `certbot-renew.sh` |
| `RootCAExpiryWarning`, `IntermediateCAExpiryWarning` | The rotation starts by itself; check that the spare key exists (`plan` says) |
| `CAExpired` (critical) | A CA has expired: rotate by hand now (`pki-rotate.sh start <scenario>`) and tell the users to enrol again |
| Federation peers | When the log or mail says a new Root CA is in use, give the peers the fingerprints and the new CA certificate (secret `<stack>/TAK-Server/FederateCA`) before you approve the root `retire` step |
| Data packages | Made-by-hand packages carry the truststore of the day. Make new ones from `truststore-phone.p12` after each CA rotation; old ones stop working at the `cut` of an Intermediate CA rotation |
| Other info alarms (`...Rotated`, `...RotationPhase`) | Nothing: a step happened |

### Moving a stack with the old PKI to the new one

A **flag day**: the new hierarchy has other CAs, so every phone enrols again (QR code), data packages made before are dead, and federation peers need the new `FederateCA`. The database, users and the Let's Encrypt certificate stay. Do it before the old Intermediate CA expires (`ca.pem`, see `openssl x509 -enddate`); do it first on a stack without users.

1. Deploy with `pki.kmsCa.enabled` and an `environmentLabel` (`--context pkiKmsCaEnabled=true --context pkiEnvironmentLabel=<Env>`). The stack keeps its old PKI and logs "already has a PKI from the old flow".
2. In the container: `pki-legacy-reset.sh reset --dry-run` (checks everything, lists the files), then `pki-legacy-reset.sh reset --restart`. It moves the old PKI, with its CA keys, to `legacy-pki-<time>/` on the EFS and starts a rolling deployment (6 to 10 minutes). The new node builds the PKI at its start and uploads the new `Admin-Cert` and `FederateCA`.
3. Check `pki-rotate.sh plan` and enrol a phone. Tell the users and the federation peers.
4. If TAKTeamManager or CloudTAK run in the account: do [CloudTAK and TAKTeamManager](#cloudtak-and-takteammanager) (new admin certificate, user certificates and ETL connections).
5. When it works: `pki-legacy-reset.sh purge legacy-pki-<time>` deletes the old CA keys. If the new node did not start the new PKI and nothing was built, `pki-legacy-reset.sh restore legacy-pki-<time>` puts the old files back.

### CloudTAK and TAKTeamManager
Both read the admin certificate from the secret `<stack>/TAK-Server/Admin-Cert`, and CloudTAK also keeps a client certificate for every user and every ETL connection.

| Service | Admin certificate | Own certificates |
|---|---|---|
| TAKTeamManager | Reads the secret every 24 hours. To be quicker, restart `TAK-<n>-TAKTeamManager` and `TAK-<n>-TAKTeamManager-SyncWorker` | None |
| CloudTAK | Reads the secret **only when a task starts**. Never refreshed | Per user and per ETL connection. They are renewed only 7 days before they expire, not when TAK Server rejects them |

**A new admin certificate** (the daily rotation 60 days before expiry; the `AdminCertRotated` info alarm; a reset; a new `admin.p12` by hand): restart CloudTAK after the secret has changed (check `LastChangedDate`; a restart before that loads the old certificate). The old certificate keeps working until it expires or until its issuer is retired, so do it within the 60 days and before any Enrollment CA `retire`.

```bash
for s in CloudTAK CloudTAK-stateful; do
  aws ecs update-service --cluster TAK-<n>-BaseInfra --service TAK-<n>-$s --force-new-deployment >/dev/null
done
```

In the log of `TAK-<n>-CloudTAK` look for `ok - Server updated from environment variables` and no `Error loading P12`. Without this restart, CloudTAK logins end in `UND_ERR_SOCKET: other side closed` as soon as TAK Server stops accepting the old admin certificate.

**After a reset, and when an Enrollment CA is retired** (user and ETL certificates that TAK Server no longer accepts): CloudTAK does not notice this at login (its certificate check throws on a TLS 1.3 rejection instead of reporting "rejected"), so users stay stuck with a dead certificate: password login fails with `UND_ERR_SOCKET`, SSO login ends in "Failed to sync groups". After the restart above:
1. Blank the stored certificates and end all sessions in the CloudTAK database (run it in the `api` container of `TAK-<n>-CloudTAK` with ECS Exec and Node's `pg` module; the connection string is in `$POSTGRES`, remove its `sslmode` parameter):
   ```sql
   UPDATE profile SET auth = '{"ca":[],"key":"","cert":""}'::jsonb;
   DELETE FROM profile_sessions;
   ```
   Add `WHERE username IN (...)` to the first statement to limit it to some users. An empty certificate is re-enrolled at the next login (SSO or password).
2. Everybody logs in again.
3. Every ETL connection and machine user: *Connections*, *Edit*, *Certificate*, *Regenerate Certificate*, *Save*. Until then the connection shows `secure:false` and its data is dropped silently. A restart does not help.

### Emergencies

| Event | Do |
|---|---|
| An admin or user key leaked | `revoke-cert.sh <cert.pem> --reason keyCompromise` (a CRL entry, in force after a rolling deployment of a few minutes). The admin certificate is also replaced by `admin-cert-rotate.sh rotate` |
| Enrollment CA or Intermediate CA key compromised | `pki-rotate.sh start enrollment` or `start intermediate`; approve each step as soon as the list of users on the old side is acceptable; then run `pki-rotate.sh run` by hand instead of waiting for the daily run, with `PKI_CLIENT_CERT_DAYS=1 PKI_ROTATION_BUFFER_DAYS=1` in the environment to shorten the waits. Revoke what was issued with `revoke-cert.sh` |
| Root CA key compromised | A flag day: runbook in [KMS_CA_KEYS.md](KMS_CA_KEYS.md#root-ca-rotation-rotationrootsh) |

## Where things are

| What | Where |
|---|---|
| Certificates, truststores, CRLs | `/opt/tak/certs/files` on the EFS (no CA keys) |
| Enrollment CA key | secret `<stack>/TAK-Server/Enrollment-CA-NN` (generation 1: the secret of the stack), copy in tmpfs |
| Root and Intermediate CA keys | KMS, aliases `alias/tak-nz-<env>-root-ca-NN`, `...-intermediate-ca-NN`; only the task role can sign; every Root CA signature raises an alert |
| Admin certificate for other services | secret `<stack>/TAK-Server/Admin-Cert` |
| Alerts | the SNS topics of the stack (`pki.kmsCa.alertEmail`, `infoEmail`) |

Related: [Let's Encrypt](LETSENCRYPT.md), [cluster lock](CLUSTER_LOCK.md), [admin.p12](ADMIN_P12.md).
