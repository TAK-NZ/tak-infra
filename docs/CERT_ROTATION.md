# Certificate management

How the certificates of a TAK Server stack are issued and renewed, and what an operator does when. Details of each script are in [KMS_CA_KEYS.md](KMS_CA_KEYS.md). Settings are in [PARAMETERS.md](PARAMETERS.md#kms-ca-keys).

## Two kinds of stack

| | Stack with `pki.kmsCa.enabled` (new stacks) | Stack without it (existing stacks) |
|---|---|---|
| PKI | Built at the first start: Root CA (R) and Intermediate CA (S) keys in AWS KMS, Enrollment CA (Cl) key in Secrets Manager and tmpfs, never on the EFS | Made by the TAK Server scripts (`makeCert.sh`), CA keys on the EFS |
| Renewal and rotation | Automatic, see below | **Manual.** Nothing renews the TAK certificates |
| Let's Encrypt (port 8446) | Automatic | Automatic and cluster-safe (the failure alarm needs `pki.kmsCa`) |

There is no migration of an existing PKI: a stack that has one keeps it, even if `pki.kmsCa` is turned on later. To get the new PKI, build a new stack (every phone enrols again).

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
| A rotation has finished (log: "is retired") | Remove the old generation from `rootCaNumbers` / `intermediateCaNumbers`, deploy, then schedule the old KMS key for deletion with a 30-day window (the container cannot). Old Enrollment CA secrets are deleted by the rotation, with a recovery window of 30 days |
| Alarm `RotationStepFailed` | Read the log group `TakServer-takserver` (`PKI:` lines). The step is retried daily; fix the cause |
| `TakServerCertRotationFailed`, `AdminCertRotationFailed` | Same; run `server-cert-rotate.sh rotate` or `admin-cert-rotate.sh rotate` by hand after the fix |
| `CertbotRenewalFailure` | Port 80 to the load balancer and DNS of `ops.<zone>` must work (HTTP-01). Run `certbot-renew.sh` |
| `RootCAExpiryWarning`, `IntermediateCAExpiryWarning` | The rotation starts by itself; check that the spare key exists (`plan` says) |
| `CAExpired` (critical) | A CA has expired: rotate by hand now (`pki-rotate.sh start <scenario>`) and tell the users to enrol again |
| Federation peers | When the log or mail says a new Root CA is in use, give the peers the fingerprints and the new CA certificate (secret `<stack>/TAK-Server/FederateCA`) before you approve the root `retire` step |
| Data packages | Made-by-hand packages carry the truststore of the day. Make new ones from `truststore-phone.p12` after each CA rotation; old ones stop working at the `cut` of an Intermediate CA rotation |
| Info alarms (`...Rotated`, `...RotationPhase`) | Nothing: a step happened |

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
