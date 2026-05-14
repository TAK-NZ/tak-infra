# TAK Server Certificate Rotation Plan

## Overview

This document describes automated rotation for all certificate types used in a TAK Server
deployment. The goal is zero-admin rotation that is robust against common failure modes, with
clear alerting when human intervention is genuinely required.

### Certificate inventory

| Certificate | Location | Validity | Issuer | Current rotation |
|-------------|----------|----------|--------|-----------------|
| Root CA | KMS asymmetric CMK (private key) + EFS (public cert) | **20–25 years** | Self-signed | Manual / never |
| Intermediate CA | Secrets Manager (private key) + EFS (public cert) | **10 years** | Root CA | Manual / never |
| TAK Server TLS | `/opt/tak/certs/files/takserver.jks` | 1 year | Intermediate CA | Manual |
| Admin client cert | `/opt/tak/certs/files/admin.p12` | 1 year | Intermediate CA | Manual |
| Let's Encrypt cert | `/etc/letsencrypt/live/<domain>/` | 90 days | Let's Encrypt | Automated (certbot) |
| User/device certs | TAK Server DB | 1 year | Intermediate CA | Manual / on-demand |

### Design principles

- **No admin intervention** for routine rotation (server cert, admin cert, Let's Encrypt)
- **Advance warning** for CA rotation, which requires coordinated client action
- **Atomic updates** — new cert written and validated before old cert is replaced
- **Rollback** — previous cert preserved until new cert is confirmed healthy
- **Cluster-safe** — all rotation logic runs in confmaker (Phase 1 of CLUSTERING.md), not in
  individual TAK nodes, preventing race conditions in multi-node deployments
- **Idempotent** — safe to run on every container start
- **HSM-grade root CA protection** — root CA private key never leaves KMS; all signing operations
  are audited via CloudTrail
- **Intermediate CA key off EFS** — intermediate CA private key retrieved from Secrets Manager
  at runtime and written only to a `tmpfs` mount, never persisted to EFS

---

## Part 1: Let's Encrypt Certificate (Already Automated)

The existing `letsencrypt-request-cert.sh` and certbot cron handle 90-day renewal. The current
implementation is largely correct. The following gaps should be addressed:

### Gap 1: Cluster-unsafe renewal

In a multi-node cluster, multiple nodes run certbot independently. The HTTP-01 challenge requires
port 80 to be served by the node requesting the cert, but the NLB distributes traffic across all
nodes — the challenge request may hit a different node than the one running certbot.

**Fix**: Move certbot to confmaker (one instance per cluster). confmaker uses an EFS lock file to
ensure only one node requests/renews at a time. The deploy hook (`letsencrypt-deploy-hook-script.sh`)
triggers an ECS rolling deployment as it does today.

### Gap 2: No alerting on renewal failure

Certbot silently fails if port 80 is blocked or rate-limited. The current script retries 10 times
then exits 1, but there is no CloudWatch alarm on this.

**Fix**: Add a CloudWatch custom metric `CertbotRenewalFailure` emitted by confmaker on failure.
Add a CloudWatch alarm on this metric with SNS notification.

### Gap 3: Staging → production transition leaves a gap

When switching `letsEncryptMode` from `staging` to `production`, the existing cert is deleted and
a new one requested. During this window (up to several minutes), the server uses the self-signed
fallback cert. This is acceptable for dev-test but should be documented.

No code change required — document the expected behaviour.

---

## Part 2: TAK Server TLS Certificate (Automated Rotation)

### Current state

`makeCert.sh server takserver` generates a 1-year server cert signed by the intermediate CA.
This only runs when `/opt/tak/certs/files/ca.pem` does not exist (i.e. first boot). There is no
rotation logic.

### Rotation trigger

confmaker checks the server cert expiry on every start and rotates if expiry is within 30 days:

```bash
check_server_cert_expiry() {
    local cert="/opt/tak/certs/files/takserver.pem"
    [[ ! -f "$cert" ]] && return 0  # missing = needs generation

    local expiry_epoch
    expiry_epoch=$(openssl x509 -noout -enddate -in "$cert" \
        | sed 's/notAfter=//' | xargs -I{} date -d "{}" +%s)
    local now_epoch=$(date +%s)
    local days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    echo "TAK server cert expires in ${days_remaining} days"
    [[ $days_remaining -le 30 ]]  # returns 0 (true) if rotation needed
}
```

### Rotation procedure

```
1. Generate new server cert with a temporary name
   makeCert.sh server takserver-new

2. Validate the new cert
   - openssl verify -CAfile intermediate-ca.pem takserver-new.pem
   - openssl x509 -noout -subject -issuer -dates -in takserver-new.pem

3. Atomic swap
   mv takserver.jks takserver.jks.prev
   mv takserver-new.jks takserver.jks
   (repeat for .pem, .key files)

4. Emit CloudWatch metric: TakServerCertRotated

5. ECS rolling deployment triggered by confmaker exit
   (TAK nodes restart and pick up new cert from EFS)
```

### Rollback

If TAK Server fails its health check after rotation, the ECS circuit breaker triggers a rollback
deployment. confmaker on the next start detects `takserver.jks.prev` and the failed health check
state, restores the previous cert, and emits a `TakServerCertRotationFailed` CloudWatch metric.

Detection of failed rotation:
```bash
# On confmaker start, if .prev exists and is newer than .jks, the swap failed
if [[ -f "takserver.jks.prev" ]]; then
    prev_age=$(stat -c %Y takserver.jks.prev)
    curr_age=$(stat -c %Y takserver.jks)
    if [[ $prev_age -gt $curr_age ]]; then
        echo "WARNING: Previous cert is newer — last rotation may have failed, restoring"
        mv takserver.jks takserver.jks.failed
        mv takserver.jks.prev takserver.jks
        emit_cloudwatch_metric "TakServerCertRotationFailed" 1
    fi
fi
```

---

## Part 3: Admin Client Certificate (Automated Rotation)

### Current state

`makeCert.sh client admin` generates a 1-year admin cert. It is uploaded to Secrets Manager on
first boot. There is no rotation logic.

### Why admin cert rotation is more complex

The admin cert is used by:
1. The TAK Server health check (`curl --cert admin.pem`)
2. `revoke-duplicate-certs.sh`
3. `check-expiring-certs.sh`
4. The admin user elevation job (`UserManager.jar certmod -A admin.pem`)

All of these must be updated atomically. If the cert is rotated but the Secrets Manager entry is
stale, external scripts will fail.

### Rotation procedure

```
1. Check expiry (same pattern as server cert, rotate if ≤ 30 days)

2. Generate new admin cert
   makeCert.sh client admin-new

3. Validate
   openssl verify -CAfile intermediate-ca.pem admin-new.pem

4. Register new cert with TAK Server BEFORE swapping files
   java -jar /opt/tak/utils/UserManager.jar certmod -A admin-new.pem
   (TAK Server now accepts both old and new admin cert)

5. Atomic swap
   mv admin.p12 admin.p12.prev
   mv admin-new.p12 admin.p12
   (repeat for .pem, .key)

6. Update Secrets Manager
   aws secretsmanager put-secret-value \
     --secret-id "${StackName}/TAK-Server/Admin-Cert" \
     --secret-binary fileb://admin.p12

7. Revoke old admin cert via API
   curl -X DELETE .../Marti/api/certadmin/cert/revoke/<old-cert-id>

8. Emit CloudWatch metric: AdminCertRotated
```

### Key point: register before swap

Step 4 registers the new cert with TAK Server while the old cert is still active. This means there
is no window where neither cert is valid. TAK Server accepts both during the transition.

---

## Part 4: Intermediate CA Rotation

### Why this is different

Rotating the intermediate CA invalidates **all** existing client certificates signed by it. Every
TAK device user will lose connectivity until they re-enroll. This cannot be done transparently —
it requires advance notice to users.

However, the process itself can be fully automated with a **pre-rotation warning period**.

With a 10-year validity and Secrets Manager-backed private key storage, intermediate CA rotation
should be an infrequent, well-signalled event rather than a routine operational burden.

### Rotation trigger

confmaker checks intermediate CA expiry on every start:
- **> 180 days remaining**: no action
- **≤ 180 days remaining**: emit `IntermediateCAExpiryWarning` CloudWatch metric + SNS alert
- **≤ 30 days remaining**: automated rotation proceeds (see below)
- **Expired**: emergency rotation, emit `IntermediateCAExpired` CloudWatch metric

The 180-day warning gives administrators 150 days to communicate the upcoming re-enrollment to
users before automated rotation begins.

### Rotation procedure

```
1. Generate new intermediate CA (signed by existing root CA)
   makeCert.sh ca intermediate-ca-new

2. Validate chain
   openssl verify -CAfile ca.pem intermediate-ca-new.pem

3. Build new truststore containing BOTH old and new intermediate CA
   keytool -import -alias intermediate-ca-old -file intermediate-ca.pem \
     -keystore truststore-transition.jks -storepass atakatak
   keytool -import -alias intermediate-ca-new -file intermediate-ca-new.pem \
     -keystore truststore-transition.jks -storepass atakatak

4. Deploy transition truststore (TAK Server now trusts both CAs)
   cp truststore-transition.jks truststore-intermediate-ca.jks
   Trigger ECS rolling deployment

5. Wait for deployment to stabilise (all nodes healthy)
   confmaker polls ECS service until runningCount == desiredCount

6. Rotate server cert and admin cert using new intermediate CA
   (follow Part 2 and Part 3 procedures above)

7. Trigger ECS rolling deployment with new server cert

8. After deployment stabilises, remove old intermediate CA from truststore
   keytool -delete -alias intermediate-ca-old \
     -keystore truststore-intermediate-ca.jks -storepass atakatak
   Trigger final ECS rolling deployment

9. Emit CloudWatch metric: IntermediateCARotated
   SNS notification: "Intermediate CA rotated — users must re-enroll"
```

### Client re-enrollment

After step 8, existing client certs signed by the old intermediate CA will be rejected. Users
must re-enroll via the TAK Server enrollment endpoint. This is the only step that requires user
action — the server-side rotation is fully automated.

To minimise disruption, steps 4–8 can be scheduled for a maintenance window by setting a
`CERT_ROTATION_MAINTENANCE_WINDOW` environment variable (cron expression). confmaker will defer
step 4 onwards until the window opens, while still emitting the warning metric.

---

## Part 5: Root CA — KMS-Backed Private Key

### Private key storage

The root CA private key is stored as a **KMS asymmetric CMK** (RSA-4096,
`RSASSA_PKCS1_V1_5_SHA_256`). The private key is generated inside KMS and never exists in
plaintext anywhere — not on EFS, not in container memory, not in Secrets Manager. All signing
operations call `kms:Sign` and are logged in CloudTrail with caller identity and timestamp.

The root CA public cert (`ca.pem`) remains on EFS as it is not sensitive.

### Toolchain

`makeRootCa.sh` and `makeCert.sh` use OpenSSL and Java keytool directly with local key files.
To use a KMS-backed key, confmaker uses **`aws-kms-pkcs11`** — a PKCS#11 provider that makes
the KMS key appear as a local HSM token to OpenSSL. This requires:

1. `aws-kms-pkcs11` installed in the confmaker Docker image
2. A PKCS#11 config file pointing at the KMS key ARN
3. OpenSSL configured to use the PKCS#11 engine for the root CA signing step only

The intermediate CA signing step (`makeCert.sh ca intermediate-ca`) is the only operation that
uses the root CA private key. All other cert operations use the intermediate CA key from
Secrets Manager and are unaffected.

### IAM policy

Only the confmaker ECS task role is granted `kms:Sign` on the root CA KMS key. The TAK Server
task role has no access. The key policy explicitly denies `kms:GetPublicKey` export to prevent
key material extraction.

### Rotation

Root CA rotation is a rare, high-impact event. With a 20–25 year validity and KMS-backed key
storage, it should not occur within the operational lifetime of a typical deployment. It cannot
be automated without admin involvement because:

1. The root CA is the trust anchor for federation — federated servers must update their
   federation truststores manually
2. All intermediate CAs must be re-signed
3. The root CA public cert is distributed to TAK clients as part of the data package

**Root CA rotation is out of scope for automated rotation.** A separate runbook should document
the procedure.

confmaker emits a `RootCAExpiryWarning` metric when root CA expiry is ≤ 365 days, giving one
year of advance notice.

---

## Part 6: User and Device Certificate Rotation

### Current state

`check-expiring-certs.sh` identifies certs expiring within 30 days and cross-references with
user activity. `revoke-duplicate-certs.sh` cleans up duplicates. Neither script rotates certs.

### Automated rotation approach

User cert rotation is different from server cert rotation because:
- TAK clients hold the private key — the server cannot rotate on their behalf
- Rotation requires the client to re-enroll or the admin to push a new data package

The practical automated approach is **proactive re-enrollment notification**, not server-side
rotation:

```
confmaker (daily cron):
1. Query /Marti/api/certadmin/cert for certs expiring in ≤ 60 days
2. For each expiring cert, check /Marti/api/clientEndPoints for recent activity
3. For active users: emit CloudWatch metric UserCertExpiryWarning with user DN
4. For inactive users: revoke the cert (no point notifying)
5. Emit summary metric: ActiveUserCertsExpiringSoon (count)
```

A CloudWatch alarm on `ActiveUserCertsExpiringSoon > 0` triggers an SNS notification to
administrators, who can then push renewal data packages via the TAK Server admin UI or API.

This is an enhancement to the existing `check-expiring-certs.sh` — the logic is already there,
it just needs CloudWatch metric emission added and to be moved into confmaker's cron schedule.

---

## Implementation Plan

### Phase A: Instrumentation (prerequisite for all other phases)

Add a shared `emit_metric` helper to confmaker:

```bash
emit_metric() {
    local metric_name="$1"
    local value="${2:-1}"
    local unit="${3:-Count}"
    aws cloudwatch put-metric-data \
        --namespace "TAK/Certificates" \
        --metric-name "$metric_name" \
        --value "$value" \
        --unit "$unit" \
        --dimensions "StackName=${StackName}" \
        2>/dev/null || echo "Warning: Failed to emit metric $metric_name"
}
```

Add CloudWatch alarms in CDK (`lib/constructs/database.ts` pattern) for:

| Metric | Alarm threshold | Action |
|--------|----------------|--------|
| `CertbotRenewalFailure` | ≥ 1 | SNS alert |
| `TakServerCertRotationFailed` | ≥ 1 | SNS alert |
| `AdminCertRotated` | ≥ 1 | SNS info |
| `IntermediateCAExpiryWarning` | ≥ 1 | SNS alert |
| `IntermediateCAExpired` | ≥ 1 | SNS critical |
| `RootCAExpiryWarning` | ≥ 1 | SNS alert |
| `ActiveUserCertsExpiringSoon` | ≥ 1 | SNS info |

### Phase B: Server cert and admin cert rotation

1. Add `check_server_cert_expiry()` and `check_admin_cert_expiry()` to confmaker
2. Add rotation logic with atomic swap and rollback detection
3. Add `emit_metric` calls
4. Test: manually set cert expiry to T-25 days, confirm rotation runs on next confmaker start
5. Test: simulate rotation failure (corrupt new cert), confirm rollback and metric emission

### Phase C: Let's Encrypt cluster safety

1. Move certbot to confmaker (Part 1, Gap 1)
2. Add EFS lock file for single-node renewal in cluster
3. Add `CertbotRenewalFailure` metric on failure
4. Test: deploy 2-node cluster, confirm only one node runs certbot

### Phase D: Intermediate CA rotation

1. Add `check_intermediate_ca_expiry()` to confmaker
2. Implement warning metric emission (≤ 180 days)
3. Implement automated rotation procedure (≤ 30 days) with transition truststore
4. Add `CERT_ROTATION_MAINTENANCE_WINDOW` support
5. Test: set intermediate CA expiry to T-25 days, confirm rotation with transition truststore
6. Test: confirm existing client certs are rejected after rotation, re-enrollment works

### Phase E: User cert expiry notifications

1. Extend `check-expiring-certs.sh` with `emit_metric` calls
2. Move to confmaker daily cron
3. Add CloudWatch alarm and SNS notification

---

## Reference: Certificate File Map

```
KMS (HSM — private key never exported)
└── Root CA private key  (RSA-4096 asymmetric CMK)           ← Part 5

AWS Secrets Manager
└── ${StackName}/CA/Intermediate-CA-Keystore                 ← Part 4
    (intermediate-ca-signing.jks as binary secret)

/opt/tak/certs/files/          (EFS — persisted)
├── ca.pem                          Root CA public cert
├── intermediate-ca.pem             Intermediate CA public cert
├── intermediate-ca-signing.p12     Intermediate CA PKCS12 (public cert only, no private key)
├── takserver.jks                   TAK Server TLS keystore  ← Part 2
├── takserver.pem                   TAK Server TLS public cert
├── takserver.key                   TAK Server TLS private key
├── truststore-intermediate-ca.jks  Client truststore         ← Part 4 (transition)
├── fed-truststore.jks              Federation truststore
├── admin.p12                       Admin client cert         ← Part 3
├── admin.pem                       Admin client public cert
├── admin.key                       Admin client private key
├── aws-acm-root.jks                AWS Root CA (for LDAPS)
└── <domain>/
    └── letsencrypt.jks             Let's Encrypt cert JKS    ← Part 1

/run/tak-ca/                   (tmpfs — in-memory only, not persisted)
└── intermediate-ca-signing.jks     Intermediate CA keystore  ← retrieved from Secrets Manager
                                    at confmaker start, used by TAK Server via bind mount
```

> `ca-do-not-share.jks` is **removed** from EFS. The root CA private key exists only in KMS.

## Reference: Rotation Schedule Summary

| Certificate | Validity | Private key storage | Rotation trigger | Warning period | Admin action required |
|-------------|----------|--------------------|-----------------:|----------------|----------------------|
| Let's Encrypt | 90 days | EFS (certbot managed) | certbot auto (60 days) | None | No |
| TAK Server TLS | 1 year | EFS | ≤ 30 days remaining | None | No |
| Admin client | 1 year | EFS | ≤ 30 days remaining | None | No |
| Intermediate CA | **10 years** | **Secrets Manager → tmpfs** | ≤ 30 days remaining | 180 days | Notify users to re-enroll |
| Root CA | **20–25 years** | **KMS asymmetric CMK** | Manual only | 365 days | Full runbook required |
| User/device certs | 1 year | TAK client device | Client re-enrollment | 60 days (notification) | Push renewal data package |
