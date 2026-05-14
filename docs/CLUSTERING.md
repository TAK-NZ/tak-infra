# TAK Server Clustering Plan

## Overview

This document describes the plan to evolve the current single-node TAK Server deployment into a
multi-node cluster. The work is broken into sequential phases, each independently deployable and
testable.

```
CURRENT STATE                          TARGET STATE

┌─────────────────────────┐            ┌──────────────────────────────────────────────┐
│   ECS Task (1 task)     │            │  ECS Service: confmaker (1 task, init)       │
│                         │            │  - CoreConfig generation                     │
│  start-tak.sh           │            │  - Schema migration                          │
│  ├── cert generation    │            │  - Let's Encrypt cert management             │
│  ├── schema migration   │            └──────────────────┬───────────────────────────┘
│  ├── CoreConfig gen     │                               │ dependsOn: COMPLETE
│  ├── letsencrypt        │            ┌──────────────────▼───────────────────────────┐
│  ├── TAK API            │            │  ECS Service: TAK nodes (N tasks)            │
│  ├── TAK Messaging      │            │  ┌─────────────┐  ┌─────────────┐           │
│  ├── TAK Plugins        │            │  │  TAK node 1 │  │  TAK node 2 │  ...      │
│  ├── TAK Retention      │            │  │  - API      │  │  - API      │           │
│  └── TAK Config         │            │  │  - Messaging│  │  - Messaging│           │
│                         │            │  │  - Plugins  │  │  - Plugins  │           │
│  Aurora Serverless v2   │            │  │  - Retention│  │  - Retention│           │
│  (1 writer)             │            │  │  - Config   │  │  - Config   │           │
└─────────────────────────┘            │  └──────┬──────┘  └──────┬──────┘           │
                                       │         │  Ignite cluster │                  │
                                       │         └────────┬────────┘                  │
                                       └──────────────────┼───────────────────────────┘
                                                          │
                                       ┌──────────────────▼───────────────────────────┐
                                       │  Supporting infrastructure                   │
                                       │  - Aurora PostgreSQL (multi-AZ)              │
                                       │  - NATS JetStream cluster                    │
                                       │  - Cloud Map (Ignite discovery)              │
                                       │  - Route 53 private zone (cluster.local)     │
                                       └──────────────────────────────────────────────┘
```

---

## Phase 1: confmaker — Split Init Logic into a Separate Container

### Goal
Remove all one-time startup logic from the TAK Server container into a dedicated `confmaker`
container that runs to completion before any TAK process starts.

### What moves into confmaker
- Certificate generation (`makeRootCa.sh`, `makeCert.sh`)
- Certificate upload to Secrets Manager
- Let's Encrypt certificate request and renewal (certbot + cron)
- CoreConfig.xml generation (`createCoreConfig.sh`)
- Schema validation and migration (`SchemaManager.jar validate/upgrade`)
- OIDC issuer public key download (`getOIDCIssuerPubKey.sh`)
- Plugin config download from S3 (`download-plugin-config.sh`)

### What stays in the TAK container
- `configureInDocker.sh init` — launches the TAK microservices
- Log forwarding (`tail -F`)
- Admin user elevation (post-startup background task)
- Retention config backup cron

### ECS task structure

confmaker runs as an **essential=false sidecar** within the same ECS task definition with
`dependsOn: START` on the TAK container. This avoids cross-task orchestration complexity while
ensuring confmaker completes before TAK starts.

```
ECS Task Definition
├── confmaker container  (essential: false)
│   └── runs to completion, exits 0
└── TAK container        (essential: true)
    └── dependsOn: confmaker (condition: COMPLETE)
```

The shared EFS volumes (`tak-certs`, `letsencrypt`, `tak-config`) provide the handoff mechanism —
confmaker writes, TAK reads.

### Let's Encrypt renewal in a cluster

In a multi-node cluster, only one node should run certbot at a time. confmaker handles the initial
request. Renewal is managed via a cron job in confmaker that uses a distributed lock (a file on EFS
with a TTL check) to ensure only one node renews at a time.

### CDK changes
- New `confmaker` container definition in `tak-server.ts`
- `dependsOn` relationship between confmaker and TAK container
- Separate log group for confmaker logs
- No new IAM roles needed — confmaker reuses the existing task role (same EFS, S3, Secrets Manager
  permissions)

### cdk.json changes
None required for Phase 1.

### Verification
- Deploy single-node with confmaker sidecar
- Confirm TAK starts only after confmaker exits 0
- Confirm CoreConfig.xml, certs, and schema migration all complete correctly
- Confirm Let's Encrypt renewal still works

---

## Phase 2: Ignite Cluster Discovery via Cloud Map + Route 53

### Goal
Enable Apache Ignite's `TcpDiscoveryKubernetesIpFinder` (already hardcoded in TAK Server) to
discover cluster nodes using AWS Cloud Map, without any changes to TAK Server source code.

### Background: what TAK Server does

From the TAK Server source, when `isClusterKubernetes()` is true:

```java
TcpDiscoveryKubernetesIpFinder ipFinder = new TcpDiscoveryKubernetesIpFinder();
ipFinder.setServiceName("takserver-ignite");          // hardcoded
ipFinder.setNamespace(takIgniteConfiguration.getIgniteClusterNamespace()); // configurable
// master URL defaults to: https://kubernetes.default.svc.cluster.local:443
```

The finder calls:
```
GET https://kubernetes.default.svc.cluster.local:443
    /api/v1/namespaces/{namespace}/endpoints/takserver-ignite
```

And expects a Kubernetes endpoints response:
```json
{
  "subsets": [{
    "addresses": [{"ip": "10.0.1.5"}, {"ip": "10.0.1.6"}]
  }]
}
```

### Architecture

```
TAK node                    Route 53 private zone       Cloud Map adapter
kubernetes.default          (cluster.local)             (Lambda)
.svc.cluster.local:443  ──► NLB (internal) ──────────► GET /api/v1/namespaces/
                                                         {ns}/endpoints/takserver-ignite
                                                              │
                                                              ▼
                                                         AWS Cloud Map
                                                         (TAK ECS service registry)
                                                         returns: [10.0.1.5, 10.0.1.6]
```

### Components to build

#### 2a. Route 53 private hosted zone

Create a private hosted zone for `cluster.local` associated with the VPC, with an A record:
```
kubernetes.default.svc.cluster.local → <internal NLB IP>
```

This makes the hardcoded master URL resolve inside the container without any container-level hacks.

CDK construct: add to `lib/constructs/` as `ignite-discovery.ts`.

#### 2b. Cloud Map namespace and service

Enable ECS Service Discovery on the TAK ECS service. Each task registers its private IP in Cloud
Map under the service name `takserver-ignite` in a namespace matching the configured
`igniteClusterNamespace`.

```typescript
// In tak-server.ts ECS service definition
cloudMapOptions: {
  name: 'takserver-ignite',
  cloudMapNamespace: privateNamespace,
  dnsRecordType: servicediscovery.DnsRecordType.A,
  dnsTtl: Duration.seconds(10)
}
```

#### 2c. Kubernetes API adapter (Lambda)

A small Lambda function (Node.js or Python) behind an internal NLB that:
1. Accepts `GET /api/v1/namespaces/{namespace}/endpoints/takserver-ignite`
2. Queries Cloud Map `DiscoverInstances` for the namespace + `takserver-ignite` service
3. Returns a Kubernetes-format endpoints JSON response
4. Serves HTTPS on port 443

TLS: The NLB uses an ACM certificate for `*.cluster.local` (private CA via ACM PCA, or a
self-signed cert imported into ACM). The Ignite IP Finder needs to trust this cert — verify
whether `TcpDiscoveryKubernetesIpFinder` has a `setVerifySslCertificate(false)` option; if not,
the cert must be trusted by the JVM truststore in the TAK container.

**Adapter response format:**
```json
{
  "kind": "Endpoints",
  "apiVersion": "v1",
  "metadata": {"name": "takserver-ignite"},
  "subsets": [{
    "addresses": [
      {"ip": "10.0.1.5"},
      {"ip": "10.0.1.6"}
    ],
    "ports": [{"port": 47500}]
  }]
}
```

#### 2d. CoreConfig.xml cluster section

The `<cluster/>` element in CoreConfig.xml (already present in the 5.6 template) needs to be
populated. Add to `createCoreConfig.sh` template substitution and `XPATH_MAPPINGS`:

```xml
<cluster enabled="true" kubernetes="true" igniteClusterNamespace="{{IGNITE_NAMESPACE}}"/>
```

New environment variables to add to `cdk.json` and wire through `tak-server.ts`:
```
TAKSERVER_CoreConfig_Cluster_Enabled=true
TAKSERVER_CoreConfig_Cluster_Kubernetes=true
TAKSERVER_CoreConfig_Cluster_IgniteClusterNamespace=tak-demo
```

#### 2e. Security group rules

New ports required for Ignite inter-node communication (ECS security group, inbound from self):

| Port | Protocol | Purpose |
|------|----------|---------|
| 47100 | TCP | Ignite communication SPI |
| 47500 | TCP | Ignite discovery SPI |
| 48100 | TCP | Ignite client connector (optional) |

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
- Confirm adapter Lambda returns correct IPs
- Confirm stale IP cleanup when a node is replaced

---

## Phase 3: NATS JetStream Cluster

### Goal
Deploy a NATS JetStream cluster for TAK Server's messaging layer. TAK Server 5.x supports NATS as
a messaging backend when configured in CoreConfig.xml.

### Architecture

NATS runs as a **separate ECS service** (not in the TAK task) with a fixed desired count of 3
(minimum for JetStream raft quorum). Each NATS node requires its own persistent storage.

```
NATS cluster (3 nodes, fixed)
├── nats-1  ←→  nats-2  ←→  nats-3
│   EFS AP1      EFS AP2      EFS AP3
│   (raft log)   (raft log)   (raft log)
```

### EFS access points

Pre-provision 3 EFS access points for NATS raft storage (one per node). The number of nodes is
fixed — scaling NATS requires reconfiguring the cluster and is a separate operation.

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

Add NATS connection details to the cluster section (verify exact element name in TAK 5.6 XSD):
```xml
<cluster enabled="true" kubernetes="true" igniteClusterNamespace="tak-demo"
         natsUrl="nats://nats.tak-nats.tak-demo.local:4222"/>
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
- Deploy 3-node NATS cluster
- Confirm JetStream raft quorum forms (`[INF] JetStream cluster leader elected`)
- Confirm TAK nodes connect to NATS
- Test node failure: remove one NATS node, confirm cluster remains operational with 2/3 nodes

---

## Phase 4: Multi-Node TAK Cluster

### Goal
Scale the TAK ECS service to `desiredCount > 1` with all nodes participating in the same Ignite
cluster and sharing state via NATS JetStream.

### Prerequisites
- Phase 1 complete (confmaker handles init, schema migration is idempotent)
- Phase 2 complete (Ignite discovery working)
- Phase 3 complete (NATS JetStream cluster running)

### Schema migration in a cluster

With multiple tasks starting in parallel, `SchemaManager.jar upgrade` must only run once.
confmaker handles this exclusively — TAK containers must not run schema migration.

Flyway (used by SchemaManager) supports distributed locking via the `lockRetryCount` and
`lockRetryInterval` parameters. Verify these are set appropriately in TAK 5.6 to handle the case
where two confmaker instances start simultaneously (e.g. during a rolling deployment).

The safest approach: confmaker uses a distributed lock via an EFS lock file with a TTL:
```bash
LOCK_FILE="/opt/tak/persistent-config/.schema-migration.lock"
# Acquire lock, run migration, release lock
```

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

| # | Question | Impact |
|---|----------|--------|
| 1 | Does `TcpDiscoveryKubernetesIpFinder` verify TLS certs? | Determines whether ACM PCA is needed for the adapter NLB |
| 2 | What is the exact CoreConfig.xml schema for the `<cluster>` element in TAK 5.6? | Required before Phase 2 CoreConfig work |
| 3 | Does TAK 5.6 support NATS as a messaging backend, and what is the CoreConfig element? | Required before Phase 3 |
| 4 | Does Flyway in SchemaManager have distributed locking enabled by default? | Determines whether EFS lock file is needed in Phase 4 |
| 5 | What is `getIgniteClusterNamespace()` reading from — CoreConfig.xml attribute or env var? | Required to know how to configure it in `createCoreConfig.sh` |

---

## Summary of Infrastructure Changes by Phase

| Component | Phase 1 | Phase 2 | Phase 3 | Phase 4 |
|-----------|---------|---------|---------|---------|
| confmaker container | ✅ New | — | — | — |
| ECS desiredCount | 1 | 1 | 1 | 2+ |
| Route 53 `cluster.local` zone | — | ✅ New | — | — |
| Cloud Map namespace | — | ✅ New | ✅ Extended | — |
| Kubernetes API adapter Lambda | — | ✅ New | — | — |
| Internal NLB (adapter) | — | ✅ New | — | — |
| NATS ECS service | — | — | ✅ New | — |
| NATS EFS access points (×3) | — | — | ✅ New | — |
| Ignite security group rules | — | ✅ New | — | — |
| NATS security group rules | — | — | ✅ New | — |
| Aurora instance count | 1 | 1 | 1 | 2 (recommended) |
| CoreConfig `<cluster>` section | — | ✅ Updated | ✅ Updated | — |
