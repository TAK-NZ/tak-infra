# TAK Server Clustering Plan

> **Status: not implemented.** This is a design/roadmap document, not a
> description of the current deployment. All work described here is tracked
> in GitHub issue [#6](https://github.com/TAK-NZ/tak-infra/issues/6) and its
> sub-issues (#7, #8, #9, #124, #125, #126, #127). Check those issues for
> current status before assuming anything below is built. This doc lives in
> `docs/roadmap/` specifically to keep unimplemented design work visually and
> physically separate from `docs/` (which documents the system as it actually
> exists today).
>
> Several details below have been corrected since first written, based on
> reading the actual TAK Server source (`TPC_TAK_Server`) and testing
> assumptions against it — see the issues above for the full reasoning trail.
> The corrections are reflected inline below.

## Overview

This document describes the plan to evolve the current single-node TAK Server deployment into a
multi-node cluster. The work is broken into sequential phases, each independently deployable and
testable.

```
CURRENT STATE                          TARGET STATE

┌─────────────────────────┐            ┌──────────────────────────────────────────────┐
│   ECS Task (1 task)     │            │  ECS Service: TAK nodes (N tasks)            │
│                         │            │  ┌─────────────┐  ┌─────────────┐           │
│  start-tak.sh           │            │  │  TAK node 1 │  │  TAK node 2 │  ...      │
│  ├── cert generation    │            │  │  - start-tak.sh (init, EFS-locked   │
│  ├── schema migration   │            │  │    for the few exclusive steps)    │
│  ├── CoreConfig gen     │            │  │  - API      │  │  - API      │           │
│  ├── letsencrypt        │            │  │  - Messaging│  │  - Messaging│           │
│  ├── TAK API            │            │  │  - Plugins  │  │  - Plugins  │           │
│  ├── TAK Messaging      │            │  │  - Retention│  │  - Retention│           │
│  ├── TAK Plugins        │            │  │  - Config   │  │  - Config   │           │
│  ├── TAK Retention      │            │  └──────┬──────┘  └──────┬──────┘           │
│  └── TAK Config         │            │         │  Ignite cluster │                  │
│                         │            │         └────────┬────────┘                  │
│  Aurora Serverless v2   │            └──────────────────┼───────────────────────────┘
│  (1 writer)             │                               │
└─────────────────────────┘            ┌──────────────────▼───────────────────────────┐
                                       │  Supporting infrastructure                   │
                                       │  - Aurora PostgreSQL (multi-AZ)              │
                                       │  - NATS cluster, 3 nodes (no single point    │
                                       │    of failure)                               │
                                       │  - Cloud Map (Ignite + NATS discovery)       │
                                       └──────────────────────────────────────────────┘
```

---

## Phase 1: Make Cluster-Unsafe Init Logic Safe (No Separate Container Needed)

> **Revised.** The original design below moved all init logic into a dedicated
> `confmaker` sidecar/service. That's not needed for resiliency: per-node init
> logic (CoreConfig.xml generation, OIDC pubkey download, S3 plugin config
> download) is already safe to run independently on every node, with no
> changes. A dedicated sidecar or separate ECS service would introduce a new
> shared-singleton dependency for node startup where none needs to exist —
> see tracking issue [#7](https://github.com/TAK-NZ/tak-infra/issues/7) for
> the full reasoning. The only real gap is that a small number of operations
> must run *exactly once* across the cluster, and those need a lock — not a
> new container.

### Goal
Keep one-time/init logic inline in `start-tak.sh` on every node, and add a
shared EFS lock-file mechanism only around the operations that are genuinely
exclusive.

### Confirmed NOT to need locking
- CoreConfig.xml generation (`createCoreConfig.sh`) — deterministic from CDK
  context/env vars per node, no shared state
- OIDC issuer pubkey download (`getOIDCIssuerPubKey.sh`), plugin config
  download from S3 (`download-plugin-config.sh`) — idempotent per-node fetches
- **Schema migration** (`SchemaManager.jar upgrade`) — resolves this doc's
  original Open Question #4. Confirmed from source: `UpgradeCommand.java`
  calls `flyway.migrate()` with no lock-related config overridden anywhere in
  `takserver-schemamanager`. Flyway's default PostgreSQL advisory lock
  already serializes concurrent `migrate()` calls across nodes — no custom
  locking needed.

### Needs a lock (shared EFS lock-file helper, TTL-based)
- **First-boot cert generation race**: `start-tak.sh` guards
  `makeRootCa.sh`/`makeCert.sh` behind "only run if `ca.pem` doesn't exist" —
  correct for single-node, but on a fresh multi-node bootstrap, multiple
  brand-new nodes could all pass that check before any of them finishes
  writing, generating conflicting root CAs.
- **Let's Encrypt renewal**: HTTP-01 challenge requires port 80 on the
  requesting node, but the NLB distributes traffic across all nodes — the
  challenge may hit a different node than the one running certbot. Only one
  node should request/renew at a time.

This same lock-file helper is designed to be reused by the certificate
rotation work (see `docs/roadmap/CERT_ROTATION.md`), which adds several more
singleton-only operations (server cert, admin cert, intermediate CA
rotation) that don't exist yet but will need the same mechanism.

### Verification
- Deploy 2+ fresh nodes simultaneously (no existing certs), confirm only one
  generates the root/intermediate/server/admin certs and others wait/skip
  correctly
- Confirm Let's Encrypt renewal only runs on one node at a time in a
  multi-node deployment
- Confirm schema migration still succeeds when 2+ nodes start in parallel
  against a fresh database (validates the Flyway-lock assumption above under
  real conditions, not just by reading source)

---

## Phase 2: Ignite Cluster Discovery via Cloud Map DNS

> **Revised.** The original design below emulated a Kubernetes API (Lambda +
> internal NLB + private Route 53 zone translating Cloud Map lookups into
> fake Kubernetes `Endpoints` JSON) so that Ignite's
> `TcpDiscoveryKubernetesIpFinder` could be used outside real Kubernetes. That
> approach is **not used** — see tracking issue
> [#8](https://github.com/TAK-NZ/tak-infra/issues/8) for the corrected
> design. It also would not have worked as originally scoped: TAK Server's
> own discovery code has no `TcpDiscoverySharedFsIpFinder` wiring at all, and
> `TcpDiscoveryKubernetesIpFinder` carries an unresolved TLS-trust question
> the simpler approach avoids entirely.

### Goal
Enable Apache Ignite cluster discovery to work across ECS tasks using AWS-native
service discovery, without any changes to TAK Server source code.

### Chosen approach: `TcpDiscoveryVmIpFinder` + Cloud Map DNS name

TAK Server's actual discovery code
(`IgniteConfigurationHolder.getIgniteConfiguration()`, in
`tak.server.ignite`) only implements two IP finders, selected by
`TAKIgniteConfig.xml`'s `clusterKubernetes` attribute:

- `clusterKubernetes="true"` → `TcpDiscoveryKubernetesIpFinder` (real
  Kubernetes API calls — not used here)
- `clusterKubernetes="false"` → `TcpDiscoveryVmIpFinder`, built from
  `igniteHost` + `igniteNonMulticastDiscoveryPort`/`PortCount`. Internally
  this just calls `ipFinder.setAddresses(Arrays.asList(host + ":" + portRange))`.

Confirmed against Ignite 2.17.0 source (the version pinned in this fork's
`gradle.properties`): `TcpDiscoveryVmIpFinder.getRegisteredAddresses()` calls
`InetAddress.getAllByName(host)` **fresh on every discovery attempt** — it
does not cache resolved IPs, and `getAllByName` returns *all* current A
records for a hostname. So pointing `igniteHost` at a Cloud Map (ECS Service
Discovery) DNS name that resolves to every current task's IP should give
Ignite a live, self-updating peer list, with zero custom adapter code.

**This assumption is unverified against real ECS networking/DNS-propagation
timing** — see the spike issue
[#124](https://github.com/TAK-NZ/tak-infra/issues/124) before building the
CDK implementation below.

### Components to build (pending #124)

#### 2a. Cloud Map namespace and service

Enable ECS Service Discovery on the TAK ECS service. Each task registers its
private IP in Cloud Map under the service name `takserver-ignite`.

```typescript
// In tak-server.ts ECS service definition
cloudMapOptions: {
  name: 'takserver-ignite',
  cloudMapNamespace: privateNamespace,
  dnsRecordType: servicediscovery.DnsRecordType.A,
  dnsTtl: Duration.seconds(10)
}
```

#### 2b. TAKIgniteConfig.xml cluster settings

`clusterEnabled`, `clusterKubernetes`, `igniteHost`, and `igniteClusterNamespace`
are all attributes on `TAKIgniteConfig.xml`'s root `<TAKIgniteConfiguration/>`
element (confirmed via `TAKIgniteConfig.xsd` and
`IgniteConfigurationHolder.java` — **not** `CoreConfig.xml`, and not an
environment variable read directly; whatever generates `TAKIgniteConfig.xml`
needs to write these). This resolves the doc's original Open Question #5.

```xml
<TAKIgniteConfiguration xmlns="http://bbn.com/marti/xml/config"
                        clusterEnabled="true"
                        clusterKubernetes="false"
                        igniteHost="takserver-ignite.{{NAMESPACE}}.local"/>
```

#### 2c. Security group rules

New ports required for Ignite inter-node communication (ECS security group,
inbound from self):

| Port | Protocol | Purpose |
|------|----------|---------|
| 47100 | TCP | Ignite communication SPI |
| 47500 | TCP | Ignite discovery SPI |

Add to `lib/utils/constants.ts`:
```typescript
export const IGNITE_PORTS = {
  DISCOVERY: 47500,
  COMMUNICATION: 47100,
} as const;
```

### Verification
- Deploy 2-node cluster
- Confirm both nodes appear in Cloud Map
- Confirm Ignite logs show successful cluster formation (`Topology snapshot [ver=2, ...]`)
- Kill one node, confirm ECS replacement is picked up without manual restart and
  topology re-stabilizes (validates the DNS-refresh assumption above under
  real conditions)

---

## Phase 3: NATS Cluster

### Goal
Deploy a 3-node NATS cluster for TAK Server's messaging layer — **3 nodes is a
resiliency requirement, not a JetStream requirement**: a single NATS instance
is a cluster-wide single point of failure, since every TAK node's
`ClusterManager` and plugin manager connect to the same NATS URL. See
"CoreConfig.xml changes" below for what TAK Server itself actually needs
(plain pub/sub) vs. what JetStream would add (durability, which TAK Server
doesn't require but which we may still want).

### Architecture

NATS runs as a **separate ECS service** (not in the TAK task) with a fixed
desired count of 3.

```
NATS cluster (3 nodes, fixed)
├── nats-1  ←→  nats-2  ←→  nats-3
```

If JetStream durability is wanted (see below — optional, TAK Server doesn't
require it), each node additionally needs its own persistent storage:

```
├── nats-1  ←→  nats-2  ←→  nats-3
│   EFS AP1      EFS AP2      EFS AP3
│   (raft log)   (raft log)   (raft log)
```

### EFS access points (only if JetStream durability is wanted)

If persistence is chosen, pre-provision 3 EFS access points for NATS raft
storage (one per node). The number of nodes is fixed — scaling NATS requires
reconfiguring the cluster and is a separate operation.

Add to `lib/constructs/efs.ts`:
```typescript
// NATS JetStream persistent storage (one per node, fixed cluster size)
this.natsNode1AccessPointId = ...
this.natsNode2AccessPointId = ...
this.natsNode3AccessPointId = ...
```

### NATS configuration

Each NATS node is configured with a static cluster routes list using Cloud Map DNS names:

```
# nats.conf
server_name: nats-1
jetstream: {
  store_dir: /data/jetstream
}
cluster: {
  name: tak-nats
  routes: [
    nats-route://nats-1.tak-nats.tak-demo.local:6222
    nats-route://nats-2.tak-nats.tak-demo.local:6222
    nats-route://nats-3.tak-nats.tak-demo.local:6222
  ]
}
```

Cloud Map provides DNS-based service discovery for the route URLs. Each NATS task registers under
its own service name (`nats-1`, `nats-2`, `nats-3`).

### CoreConfig.xml changes

> **Resolved.** This doc's original Open Question #3 asked whether TAK Server
> supports NATS and what the CoreConfig element is. Confirmed from source
> (`CoreConfig.xsd`, `ClusterManager.java`): TAK Server's `<cluster/>` element
> (in `CoreConfig.xml`, not `TAKIgniteConfig.xml`) has `natsURL` and
> `natsClusterID` attributes, and `ClusterManager.onApplicationEvent()` really
> does call `Nats.connect(config.getNatsURL())` on startup for cluster
> messaging. The plugin manager connects independently via the same URL.
> **TAK Server's own client is plain NATS pub/sub (`io.nats:jnats`), not
> JetStream** — nothing in the calling code touches durable streams. JetStream
> (and the EFS-backed raft persistence Phase 3 describes above) is only
> needed if message durability across NATS restarts is wanted for its own
> sake; TAK Server itself doesn't require it. See
> [#9](https://github.com/TAK-NZ/tak-infra/issues/9) for the decision.

```xml
<cluster enabled="true" kubernetes="false"
         natsURL="nats://nats.tak-nats.tak-demo.local:4222"
         natsClusterID="takserver"/>
```

### cdk.json changes

```json
"nats": {
  "clusterSize": 3,
  "clientPort": 4222,
  "clusterPort": 6222,
  "taskCpu": 512,
  "taskMemory": 1024
}
```

### Security group rules

| Port | Protocol | Purpose |
|------|----------|---------|
| 4222 | TCP | NATS client connections (from TAK nodes) |
| 6222 | TCP | NATS cluster routing (between NATS nodes) |
| 8222 | TCP | NATS monitoring HTTP (internal only) |

### Verification
- Deploy 3-node NATS cluster, confirm cluster forms
- If JetStream is enabled: confirm raft quorum forms (`[INF] JetStream cluster leader elected`)
- Confirm TAK nodes connect to NATS
- Test node failure: remove one NATS node, confirm cluster remains operational with 2/3 nodes and TAK nodes stay connected

---

## Phase 4: Multi-Node TAK Cluster

### Goal
Scale the TAK ECS service to `desiredCount > 1` with all nodes participating in the same Ignite
cluster and sharing state via NATS JetStream.

### Prerequisites
- Phase 1 complete (init logic cluster-safe, schema migration confirmed safe by default)
- Phase 2 complete (Ignite discovery working)
- Phase 3 complete (NATS cluster running)

### Schema migration in a cluster

> **Resolved** — see Phase 1 above and
> [#7](https://github.com/TAK-NZ/tak-infra/issues/7). `SchemaManager.jar
> upgrade` (`UpgradeCommand.java`) calls `flyway.migrate()` with no
> lock-related config overridden anywhere in `takserver-schemamanager`.
> Flyway's default PostgreSQL advisory lock already serializes concurrent
> `migrate()` calls, so multiple nodes running schema migration in parallel
> during a fresh or rolling deployment is safe without any custom EFS lock
> file — one instance acquires the lock and migrates, the others block/retry
> until it's done, then find nothing left to do. Still worth verifying this
> holds under real conditions (see Phase 1 verification steps), since this
> is confirmed by reading the library's documented default behavior, not by
> testing it against this specific deployment yet.

### Rolling deployments

With `desiredCount: 2` and `minHealthyPercent: 50`, ECS will replace one node at a time. The
Ignite cluster tolerates one node being absent during replacement — verify this with the Ignite
`TcpDiscoverySpi` timeout configuration.

Set in CoreConfig.xml cluster section (if configurable):
```xml
<!-- Allow up to 60s for a node to rejoin before declaring it failed -->
```

### Health checks per node

The existing health check (`curl https://localhost:8443/actuator/health/readiness`) works per-node
and does not need to change. Each ECS task is independently health-checked.

### NLB target group behaviour

The NLB already distributes connections across all healthy targets. No changes needed — adding a
second task automatically registers it in all target groups.

### cdk.json changes

```json
"ecs": {
  "desiredCount": 2   // increase from 1
}
```

For production, `desiredCount: 3` provides full Ignite cluster redundancy (one node can fail
without losing quorum).

### Verification
- Deploy 2-node cluster
- Confirm both nodes join the same Ignite cluster (`Topology snapshot [ver=2, servers=2]`)
- Confirm CoT messages sent to node 1 are visible on node 2
- Confirm a node replacement does not drop connected clients on the surviving node
- Confirm schema migration runs exactly once during a fresh deployment
- Load test: confirm Aurora ACU stays below ceiling with 2x connection pool

---

## Open Questions

All originally-listed open questions have been resolved by reading the TAK
Server source directly — see the tracking issues for the full reasoning
trail. Kept here for historical record:

| # | Question | Resolution |
|---|----------|--------|
| 1 | Does `TcpDiscoveryKubernetesIpFinder` verify TLS certs? | Moot — this finder is no longer used. Phase 2 now uses `TcpDiscoveryVmIpFinder` + Cloud Map DNS, which has no TLS component. |
| 2 | What is the exact CoreConfig.xml schema for the `<cluster>` element in TAK 5.6? | Confirmed: `enabled`, `natsURL`, `natsClusterID`, `kubernetes`, `cacheConfig`, `metricsIntervalDelaySeconds`, `metricsIntervalSeconds` (`CoreConfig.xsd`). Note this is a different file from `TAKIgniteConfig.xml`, which holds the Ignite-specific `clusterEnabled`/`clusterKubernetes`/`igniteHost`/`igniteClusterNamespace` attributes (see Phase 2). |
| 3 | Does TAK 5.6 support NATS as a messaging backend, and what is the CoreConfig element? | Yes, confirmed real and wired up (`ClusterManager.java`, `PluginStarter.java`) — plain NATS pub/sub, not JetStream. See Phase 3. |
| 4 | Does Flyway in SchemaManager have distributed locking enabled by default? | Yes — confirmed via `UpgradeCommand.java`, no lock config overridden. See Phase 1/4. |
| 5 | What is `getIgniteClusterNamespace()` reading from — CoreConfig.xml attribute or env var? | `TAKIgniteConfig.xml` attribute (`igniteClusterNamespace`, default `"takserver"` per `TAKIgniteConfig.xsd`) — not an env var, and not `CoreConfig.xml`. Whatever generates `TAKIgniteConfig.xml` needs to set it, not `createCoreConfig.sh` (which generates the other file). |

---

## Summary of Infrastructure Changes by Phase

| Component | Phase 1 | Phase 2 | Phase 3 | Phase 4 |
|-----------|---------|---------|---------|---------|
| EFS lock-file helper (shared w/ cert rotation) | ✅ New | — | — | — |
| ECS desiredCount | 1 | 1 | 1 | 2-3 |
| Cloud Map namespace | — | ✅ New | ✅ Extended | — |
| NATS ECS service (3-node, fixed) | — | — | ✅ New | — |
| NATS EFS access points (×3, only if JetStream durability wanted) | — | — | Optional | — |
| Ignite security group rules | — | ✅ New | — | — |
| NATS security group rules | — | — | ✅ New | — |
| Aurora instance count | 1 | 1 | 1 | 2 (recommended) — see [#126](https://github.com/TAK-NZ/tak-infra/issues/126) for writer-failover RTO |
| TAKIgniteConfig.xml cluster attrs | — | ✅ Updated | — | — |
| CoreConfig.xml `<cluster>` section | — | — | ✅ Updated | — |

Also see [#125](https://github.com/TAK-NZ/tak-infra/issues/125) (Phase 4
scale-out) and [#127](https://github.com/TAK-NZ/tak-infra/issues/127)
([Spike] validating this all actually holds at the 50,000-user target).
