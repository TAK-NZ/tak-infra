# Proposal: Live Scenario Test Suite for TAK Server

> **Status: not implemented.** This is a design/roadmap document, not a
> description of the current deployment. All work described here is tracked
> in GitHub issue [#145](https://github.com/TAK-NZ/tak-infra/issues/145) and
> its sub-issues (#146–#150). Check those issues for current status before
> assuming anything below is built. This doc lives in `docs/roadmap/`
> specifically to keep unimplemented design work visually and physically
> separate from `docs/` (which documents the system as it actually exists
> today).

## Problem

Nearly every serious TAK Server incident this project has hit (LDAP X.509 group
lookup returning zero groups on 5.8, the `authRequired`/anonymous-connection gap,
the CoreConfig-regeneration scrubber bug, the messaging-process JVM crash from the
CloudWatch/EKU SSL fix) shares a pattern: **the bug was invisible to every test we
had, and only visible by exercising the actual client-server protocol against a
running server.**

The existing test suite is thorough at two layers, but has a gap between them:

| Layer | What it tests | Example | What it can't catch |
|---|---|---|---|
| `test/unit/**` (Jest) | CDK constructs synthesize the right CloudFormation | `tak-server.test.ts` asserts env vars are set on the task definition | Whether TAK Server's *runtime* does anything sensible with those env vars |
| `test/CoreConfig/` (bash + xmllint) | `createCoreConfig.sh` produces XSD-valid XML for given inputs | Confirms `<ldap url="...">` is well-formed | Whether that URL, once live, lets `ctx.lookup()` resolve a user's DN correctly — this is exactly the bug we shipped and didn't catch |
| **(missing)** | Whether a real client, talking real CoT/TLS to a real running server, gets the behavior an operator expects | Can user A see user B's position? | — |

Both existing layers would have passed on every commit leading up to the 5.8 LDAP
regression. Only a test that actually authenticates two identities and checks
whether CoT flows between them would have caught it, at merge time instead of in
a live-user incident.

## Goal

A small suite of **scenario tests** that run against a real, deployed TAK Server
(never production — see [Environment](#environment)) and assert on user-observable
behavior: can this identity connect, does this CoT reach that subscriber, does
mission sync actually sync. Not a replacement for the existing layers — a third
layer on top of them.

## Scope: initial scenario set

Prioritized by how directly each one maps to a bug we've actually shipped, and by
implementation cost. This is deliberately a small starter set, not a
comprehensive protocol conformance suite.

### Tier 1 — ship first

These three would have caught the actual 5.8 incident directly.

1. **Positive delivery**: identity A and identity B share an LDAP group. A sends a
   CoT (simulated position update). B receives it within a bounded timeout.
2. **Negative delivery**: identity C is *not* in that group. C does not receive
   A's CoT. (We have zero negative tests anywhere today. This is the shape of
   test that catches "silently returns nothing" bugs like the one we shipped —
   a positive-only test suite cannot distinguish "routes correctly" from "drops
   everything and reports success.")
3. **Unauthenticated rejection**: a TLS connection to 8089 with no client
   certificate is rejected outright, not silently admitted with zero groups.
   Directly validates the `Network_Input_8089_AuthRequired` fix.

### Tier 2 — next

4. **Group membership change propagation**: change a test identity's LDAP group
   membership, confirm the routing change takes effect within
   `updateinterval` (1000ms) plus a reasonable margin.
5. **Mission sync round-trip**: identity A creates a mission, adds a CoT/map
   item to it via the Mission API, identity B (invited/subscribed to the
   mission) retrieves it.
6. **Cert self-enrollment**: authenticate to `/Marti/api/tls/config` with a test
   LDAP identity's credentials, confirm a usable client cert comes back, and
   that cert can then open a working 8089 connection.

### Tier 3 — later, higher effort or lower incident-history payoff

7. Federation between two TAK Server instances.
8. WebTAK/OIDC login round-trip.
9. tak-gpt plugin chat/marker routing (would directly validate this session's
   dest-UID fix, but requires a Bedrock-backed bot to be configured in the test
   environment).

## Architecture

### A minimal CoT/TLS test client

None of this exists in the repo today (confirmed: no TLS socket client, no CoT
XML construction, no XML library as a real dependency — `fast-xml-parser` is
currently only a transitive-dependency security pin in `package.json`'s
`overrides`, not used in code). This needs to be built from scratch, but it's
small:

- Node's built-in `tls` module, presenting a client cert (`cert`/`key`/`ca`
  options on `tls.connect`), talking to port 8089.
- CoT messages are plain XML over that socket — no framing beyond the XML
  document boundaries TAK Server already expects. A hand-rolled template string
  (the same approach `TAKMessageGenerator.java` and `TAKChatGenerator.java` use
  server-side, just in TypeScript) is enough; a full XML parser is only needed
  for reading responses/received CoT, where promoting `fast-xml-parser` from
  transitive pin to real dependency is the path of least resistance.
- This is genuinely a new capability for this repo, not a wrapper around
  something that already exists — budget real implementation time for it, and
  treat the first version as intentionally minimal (send one CoT type, parse
  enough of a received CoT to extract `uid`/`type`/group markers).

Suggested location: `test/scenario/lib/cot-client.ts` (a `TakClient` class:
`connect(cert, key)`, `sendCot(xml)`, `waitForCot(predicate, timeoutMs)`,
`close()`), kept separate from the Jest unit tests since it has a fundamentally
different runtime dependency (a live network target) and almost certainly needs
its own Jest config (longer timeouts, `testEnvironment: 'node'`, no coverage
collection).

### Test identity & cert provisioning

This is the part of the design with the most open questions, because LDAP/user
provisioning is owned by a separate repo (`auth-infra`), not this one — this repo
only consumes LDAP via CloudFormation cross-stack imports
(`AUTH_EXPORT_NAMES.LDAP_SERVICE_USER_SECRET` etc. in `lib/tak-infra-stack.ts`).
There is no existing API or IaC in `tak-infra` for provisioning LDAP users/groups.
Two viable approaches:

- **Option A — provision in auth-infra.** Add a small, clearly-named set of
  permanent test identities/groups there (e.g. `test-scenario-user-a`,
  `test-scenario-user-b`, `test-scenario-user-c`, group
  `tak_ScenarioTestGroup`), following whatever pattern that repo already uses
  for LDAP entries. Lowest ongoing complexity, but couples this suite to a
  cross-repo change and means test identities are long-lived, static fixtures
  (fine for Tier 1–2; a slight liability if you want per-test-run isolation
  later).
- **Option B — provision via Authentik's REST API at test-run time.**
  `lib/constructs/webtak-oidc-setup.ts` already calls Authentik's API
  programmatically (for OIDC application setup) — that's a real precedent in
  this codebase, though for a different object type (OIDC apps, not LDAP
  users/groups). This would let the test suite create/tear down identities per
  run, but is more moving parts and more can silently drift if Authentik's LDAP
  outstanding-sync behavior changes.

**Recommendation for Tier 1: start with Option A** — a small number of static,
clearly-named test identities is enough for the three Tier 1 scenarios and
avoids building test-infrastructure-for-the-test-infrastructure before proving
the approach out. Revisit Option B if/when Tier 2's group-membership-change test
needs to mutate group membership programmatically and repeatedly.

For **certs**: use the LDAP self-enrollment flow
(`/Marti/api/tls/config` on port 8446, LDAP basic-auth) to mint a client cert for
each test identity — this only needs LDAP credentials, not filesystem/shell
access to the container, and is the same mechanism a real ATAK/CloudTAK client
uses. No new server-side tooling needed; this is existing TAK Server behavior,
just not something this repo has scripted a client for yet. Cache the issued
cert/key for the duration of a test run rather than re-enrolling per test.

### Where this runs

**Never against production.** Plug into `demo-deploy.yml`'s existing, literal
placeholder:

```yaml
- name: Run Automated Tests
  run: |
    echo "Placeholder for automated tests"
    # TODO: Add health checks and integration tests
```

This step already runs after a real deploy, after a `sleep
${{ vars.DEMO_TEST_DURATION }}` settling period, in the `demo` GitHub
environment, against a stack deployed with **production configuration**
(`--context envType=prod`) for realism, and is unconditionally followed by
`revert-to-dev-test` (`if: always()`) — so a failing scenario suite here doesn't
strand the demo environment in a bad state. This is close to an ideal existing
insertion point; no new environment or pipeline stage is needed for Tier 1.

`production-deploy.yml` has no equivalent post-deploy test step today. Adding one
there is a separate, later decision — Tier 1i's job is to prove the suite is
reliable in `demo` first.

### Directory/config structure

```
test/
  scenario/
    lib/
      cot-client.ts        # minimal TLS+CoT client described above
      cot-templates.ts      # CoT XML builders (position update, chat, etc.)
      test-identities.ts    # loads test identity certs/creds from Secrets Manager
    tier1/
      positive-delivery.test.ts
      negative-delivery.test.ts
      unauthenticated-rejection.test.ts
    tier2/
      group-membership-propagation.test.ts
      mission-sync.test.ts
      cert-self-enrollment.test.ts
    jest.scenario.config.json   # separate Jest config: longer timeouts, no coverage
```

A separate `npm run test:scenario` script, **not** part of `npm test`/
`test:coverage` (which `cdk-test.yml` runs on every push/PR) — this suite needs a
live deployed server and real network access, so it can only run where that's
true (post-deploy in `demo-deploy.yml`), never in the fast pre-deploy CI gate.

## Design constraints to get right early

- **Timeouts and retries are not optional.** CoT delivery is asynchronous;
  `updateinterval` is 1000ms and real network/TLS handshake latency adds more.
  Every "did X receive Y" assertion needs a bounded poll/wait, not an immediate
  check — get this pattern right in the shared `cot-client.ts` helper once,
  rather than reinventing it per test.
- **Negative tests need a *longer* timeout than positive tests, and a clear
  reason.** A negative test that only waits as long as a positive test's
  expected-fast-path risks false negatives (test passes because it didn't wait
  long enough, not because delivery was actually blocked). This is the exact
  inverse failure mode of what we're trying to catch — get it wrong and the
  negative test is worse than useless.
- **Test data must not read as real operational data.** Test identities,
  groups, and any CoT payloads created by this suite should be unmistakably
  test fixtures (naming convention, e.g. `test-scenario-*`) so nobody mistakes
  them for real users during an incident review, and so they're easy to
  exclude from monitoring/alerting if needed.
- **Idempotent and safe to re-run.** Mission-sync and cert-enrollment tests
  create server-side state (missions, certs). Each test run needs to either
  clean up after itself or be safely re-runnable without accumulating cruft
  (e.g. delete the mission it created, revoke/reuse the cert rather than
  minting a new one every run).

## What this proposal does not cover

- Concrete Authentik API calls for Option B (needs a decision on A vs B first).
- Exact assertions/thresholds for "did delivery happen within a reasonable
  time" (needs a first working version to calibrate against, not a guess).
- Whether/how to run this suite against `production-deploy.yml` (deliberately
  deferred until Tier 1 is proven in demo).
- tak-gpt/Bedrock-dependent scenarios (Tier 3) — these need a configured bot in
  the test environment, a separate piece of setup from the core suite.

## Suggested next step

If this direction looks right: implement Tier 1 only (3 scenarios,
`cot-client.ts`, static test identities via Option A), wire it into
`demo-deploy.yml`'s existing placeholder, and treat it as a checkpoint before
committing to Tier 2's larger scope (mission sync, programmatic cert
enrollment).
