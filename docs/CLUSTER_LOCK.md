# Cluster lock for steps that run once per cluster

Most of what `start-tak.sh` does is safe to run on every node at once: `CoreConfig.xml` is built from the same settings on each node, the OIDC key and plugin configuration are downloaded per node, and the schema migration is serialized by Flyway's PostgreSQL advisory lock. A few steps change shared state on the EFS and must run on one node at a time. They use `cluster-lock.sh` (#7).

| Step | Lock name | Where | What a waiting node does |
|---|---|---|---|
| First-boot PKI of `pki.kmsCa` stacks | `pki-bootstrap` | `pki-bootstrap.sh` | Finds `pki-state.json` of the first node and only restores the Enrollment CA key into its own tmpfs |
| First-boot certificates of the TAK Server scripts (stacks without `pki.kmsCa`) | `first-boot-certs` | `start-tak.sh` | Finds `ca.pem` and skips |
| Let's Encrypt request, change or removal | `letsencrypt` | `start-tak.sh`, around `letsencrypt-request-cert.sh` | Finds the certificate the first node got and keeps it. Waits up to 30 minutes |
| Let's Encrypt renewal (cron, twice a day) | `certbot-renew` | `/etc/cron.d/certbot`, rewritten by `start-tak.sh` | Skips this round (`--wait 0`); the other node renews, and the certificate is on the shared EFS |

The certificate rotations of the CA overhaul (#131, #132, #135, #169, #171, #172) take the same lock with their own names.

## Using it

```bash
source /opt/tak/scripts/cluster-lock.sh
with_cluster_lock <name> <command> [args...]       # <command> can be a shell function

/opt/tak/scripts/cluster-lock.sh run [--ttl S] [--wait S] <name> -- <command> [args...]
```

The command's exit status is returned. `75` means the lock was not obtained within the wait time, `64` wrong usage. After the wait, the command must check again whether its work is still needed, because the node that held the lock has probably done it.

Under `set -e` a failing command ends the calling shell (`with_cluster_lock` does not use `cmd || ...`, which would switch `set -e` off inside the command). The lock is then released by the heartbeat, within TTL/4 seconds.

## How it works

- The lock is the directory `/opt/tak/certs/files/.locks/<name>.lock` on the EFS. `mkdir` is atomic on EFS (NFSv4), so only one node creates it. The file `owner` in it holds a random token, an expiry time and the host name.
- A background loop in the holder moves the expiry forward every TTL/4 seconds (TTL: 90 s, `CLUSTER_LOCK_TTL`). A long command needs no long TTL. When the shell that took the lock ends, the loop releases the lock.
- A node that dies stops the heartbeat, and the lock expires after the TTL. A waiting node breaks an expired lock under a second short lock (`<name>.lock.breaker`) and checks the expiry again inside it, so two waiters cannot both break the lock and both take it.
- Only the holder's token releases a lock. A holder whose heartbeat was late for more than the TTL finds another token, logs `no longer ours`, and does not remove the new owner's lock.
- Settings: `CLUSTER_LOCK_DIR`, `CLUSTER_LOCK_TTL` (90), `CLUSTER_LOCK_WAIT` (600 s; 0 = do not wait), `CLUSTER_LOCK_POLL` (2 s).

Limits:
- The expiry is a wall-clock time written by one node and read by others. ECS tasks use the Amazon Time Sync Service; a skew of a few seconds is far below the TTL.
- A holder that is alive but frozen for longer than the TTL loses the lock to a waiter. The commands under the lock are idempotent where this matters (certbot, PKI restore), and the holder logs the loss.
- This is not a lock against the database: use it only for work on the shared EFS and for AWS calls that two nodes must not make at once.

## Tests

`test/KmsCa/test-cluster-lock.sh` (runs in CI, needs only bash): exit codes and usage errors, a shell function as the command, six contenders that never overlap, the first-boot pattern (four nodes, work done once), `--wait 0` and timeouts, the heartbeat keeping a lock beyond the TTL, an expired lock broken after the owner died, six waiters on one expired lock, release after `set -e` and after `kill -9` of the holder, the caller's EXIT trap not run by the heartbeat, no release of a lock that was taken over, and the cron line rewrite. `test/KmsCa/test-pki-bootstrap.sh` adds three nodes starting together on a fresh stack (one builds, two restore) and a node that sees `ca.pem` of a node still bootstrapping.

Not covered by automated tests: two real ECS tasks on one EFS. That is the check in #7 (deploy two fresh nodes at once, and watch for the `took pki-bootstrap.lock` and `waiting for` lines in the log).
