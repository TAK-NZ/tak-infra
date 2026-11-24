# Let's Encrypt certificates for TAK Server

The TLS certificate of the public name (`takserver.servicename`, port 8446 and the web endpoints) comes from Let's Encrypt when `letsEncryptMode` is `staging` or `production` (`docs/PARAMETERS.md`). With any other value TAK Server uses its own certificate.

## Flow

| When | What | Script |
|---|---|---|
| Every start | Check `/etc/letsencrypt/live/<domain>`. Certificate of the requested type: keep. Other type (staging against production): delete and request again. None: wait until this node is the only one that is ready, then run `certbot certonly --standalone` (HTTP-01 on TCP/80), up to 10 attempts 30 s apart. A new certificate triggers an ECS deployment so TAK Server loads it. | `letsencrypt-request-cert.sh`, started by `start-tak.sh` under the cluster lock `letsencrypt` |
| Twice a day (cron, random delay up to 12 h) | `certbot -q renew`. Certbot renews 30 days before expiry (about every 60 days). The deploy hook triggers an ECS deployment so TAK Server loads the new certificate. | `certbot-renew.sh`, under the cluster lock `certbot-renew` |

The certificate and the account live on the EFS (`/etc/letsencrypt`), so a new task finds them. The cron file is copied to `/etc/letsencrypt/certbot.cron` and restored at start; `start-tak.sh` rewrites its line to call `certbot-renew.sh`.

## Why cron calls `certbot-renew.sh`

Cron jobs do not get the container's environment: only `HOME`, `LOGNAME`, `PATH`, `PWD` and `SHELL` (checked on a running task). Without `ECS_Cluster_Name` and `ECS_Service_Name` the deploy hook exits at once, so a renewed certificate was never loaded, and without `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` no AWS call has the task role. `start-tak.sh` saves the needed variables (`ECS_Cluster_Name`, `ECS_Service_Name`, `StackName`, `AWS_*`) to `/run/tak-cron.env` (mode 600, inside the container, not on the EFS) with `certbot-renew.sh write-env`, and `certbot-renew.sh` loads them.

## Failure alert

- `CertbotRenewalFailure` (namespace `TAK/Certificates`, dimension `Stack`) is emitted when `certbot renew` exits non-zero, and when a request at start fails all attempts. The alarm of `docs/KMS_CA_KEYS.md` (metrics and alarms) sends it to the alert SNS topic; set `pki.kmsCa.alertEmail` to receive it by e-mail.
- A renewal that is skipped because another node holds the lock is not a failure.
- The alarm exists when `pki.kmsCa` is enabled, because the alarms are part of that setting.

## Switching from staging to production

When `letsEncryptMode` changes from `staging` to `production`, the next start finds a certificate of the wrong type, deletes it and requests a new one. Until the new certificate is issued and the ECS deployment finishes (several minutes), TAK Server uses its self-signed certificate, and clients that rely on the public certificate (browsers, WebTAK, QR enrolment) see a certificate error. This is expected and acceptable for dev-test; do the switch outside of operations.

## Limits with more than one node

- The cluster lock makes sure only one node requests or renews at a time. It does not make the HTTP-01 challenge reach that node: the load balancer sends the validation request on TCP/80 to any healthy node. The request script therefore waits until exactly one task is running and healthy before it asks for a certificate, and renewal of a multi-node cluster can fail when the challenge lands on another node. The robust fix is DNS-01 (Route 53) instead of HTTP-01, which needs no port 80. Not done: Try runs one node.
- On a failure of the renewal the metric is the only signal; there is no automatic retry before the next cron round (12 hours). Certbot starts renewing 30 days before expiry, so a failing renewal has about 60 attempts before the certificate expires.

## Tests

`test/KmsCa/test-certbot-renew.sh` (runs in CI, needs only bash): saved environment (what is copied, quoting, mode 600), renewal with a cron-like empty environment, the exit status and the metric on failure, a lock held by another node, a missing environment file, the cron line rewrite (plain Debian line, the line of the first version of #7, repeated run), and the metric after the failed attempts of a request. Not covered by automated tests: a real renewal with a real deploy hook. Checked on the dev-test stack instead (see #130).
