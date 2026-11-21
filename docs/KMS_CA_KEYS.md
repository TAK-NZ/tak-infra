# Root CA and Intermediate CA keys in AWS KMS

Tracked in [#136](https://github.com/TAK-NZ/tak-infra/issues/136), part of the certificate rotation epic [#128](https://github.com/TAK-NZ/tak-infra/issues/128). The target PKI is described in [#171](https://github.com/TAK-NZ/tak-infra/issues/171).

New stacks keep the private keys of the Root CA (R) and the Intermediate CA (S) in AWS KMS. They never exist as files on EFS, in container memory or in Secrets Manager. The Enrollment Signing CA (Cl) is not in KMS: TAK Server signs client certificates in-process from a keystore.

This page covers the keys, how the container signs with them, and how to operate them. This change does not yet use the keys on first boot: that is [#189](https://github.com/TAK-NZ/tak-infra/issues/189).

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

## Retiring a key

When a rotation is complete (#169, #172), schedule the old key for deletion with the full window:

```bash
aws kms schedule-key-deletion --key-id alias/tak-nz-try-intermediate-ca-01 --pending-window-in-days 30
```

The task role has no permission to do this. Afterwards remove the number from `rootCaNumbers` / `intermediateCaNumbers`; CloudFormation retains the key either way.

## Tests

- `npx jest test/unit/constructs/ca-kms-keys.test.ts test/unit/utils/pki-names.test.ts`: key spec, policy, alias names, alert rule.
- `test/KmsCa/test-kms-ca.sh`: the wrapper end to end with SoftHSM standing in for KMS (root, intermediate, cross-certificate, enrollment CA, server cert, CRL, wrong-key and bad-input cases). Needs `softhsm2 opensc libengine-pkcs11-openssl jq`. It runs in CI.
- Not covered by automated tests: the real KMS call and a task role in ECS. The module was validated against KMS in #134.
