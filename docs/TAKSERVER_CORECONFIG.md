# TAK Server CoreConfig Environment Variable System

## Overview

`CoreConfig.xml` is generated on every container start by
`docker-container/scripts/createCoreConfig.sh`, using a version-specific
template (`docker-container/scripts/templates/coreconfig-{5.4,5.5,5.6}.xml`)
combined with environment variables sourced from CDK context and/or an S3
configuration file (`takserver-config.env`).

**Only the environment variables listed in this document have any effect.**
Setting any other `TAKSERVER_CoreConfig_*` variable — even if it looks like a
valid CoreConfig XML attribute path — does nothing, because
`createCoreConfig.sh` never reads it. This document was previously out of
sync with the script and documented many variables that were never wired
up; it has been rewritten to match the actual script behavior exactly. If
you need a setting that isn't listed here, it must be added to
`createCoreConfig.sh` (and usually the templates) before it will work — see
[Adding a New Setting](#adding-a-new-setting) below.

## Configuration Persistence and Priority

`CoreConfig.xml` is fully regenerated from the version-specific template plus
CDK/S3-provided environment variables on **every** container start. This means:

- **S3 config file / CDK context is the single source of truth** for every
  section of `CoreConfig.xml` except `<federation>` (see below). Any change
  made only through the TAK Server admin web UI or REST API — LDAP settings,
  security/TLS, filter/QoS, mission flags, VBM, etc. — will be **silently
  reverted** on the next container restart or deployment. To make those
  changes stick, update the S3 `takserver-config.env` file or the relevant
  CDK context and redeploy/restart.
- **`<federation>` is the one exception.** TAK Server writes admin-configured
  federation state (e.g. outgoing federation connections added via the Marti
  admin UI) directly back to `CoreConfig.xml` at runtime
  (`setAndSaveFederation()`). Because bouncing a container is not a
  reasonable way to configure federation during an operational/emergency
  situation, `createCoreConfig.sh` preserves the entire existing
  `<federation>` element verbatim across every regeneration, rather than
  regenerating it from the template. If no existing `CoreConfig.xml` is
  found (e.g. first boot), `<federation>` is generated from the template and
  CDK/S3 settings as normal.

> **Note**: Outside of `<federation>`, do not rely on making changes through
> the admin UI — they will not survive a restart. Manage every other section
> through the S3 configuration file or CDK context instead.

## Environment Variable System

### Case Sensitivity Requirements

`createCoreConfig.sh` reads environment variables by their **exact name** —
there is no case-insensitive fallback. Variable names in this document must
be copied exactly.

### Naming Convention

```
TAKSERVER_CoreConfig_{XmlPath}_{AttributeName}
```

This convention is followed loosely by the variables below, but it is not a
generic mechanism — each variable name below is individually wired to a
specific XML attribute in `createCoreConfig.sh`. There is no naming
convention that will "just work" for an XML attribute that isn't explicitly
listed here.

## Precedence: S3 File vs. CDK Context

The ECS task definition sets some `TAKSERVER_CoreConfig_*` values directly as
container `environment` entries, computed from CDK context
(`cdk.json`/`--context`). In AWS ECS, task-definition `environment` values
**always take precedence** over `environmentFiles` (the S3 mechanism) for
the same variable name. This means the variables below are effectively
**not controllable via the S3 file** — whatever CDK computes always wins,
regardless of what the S3 file says:

| Variable | Controlled by |
|---|---|
| `TAKSERVER_CoreConfig_Network_CloudwatchEnable` | `cdk.json` → `takserver.enableCloudWatchMetrics` |
| `TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak` | `cdk.json` → `webtak.enabled` |
| `TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak` | `cdk.json` → `webtak.enabled` |
| `TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix` | `cdk.json` → `takserver.ldapGroupPrefix` (only when that context key is set) |
| `TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex` | `cdk.json` → `takserver.ldapGroupPrefix` (only when that context key is set) |
| `TAKSERVER_CoreConfig_OAuth_UseTakServerLoginPage` | `cdk.json` → `webtak.useTakServerLoginPage` (only when WebTAK OIDC secrets exist) |
| `TAKSERVER_CoreConfig_OAuth_UsernameClaim` | Hardcoded `preferred_username` in `tak-server.ts` (only when WebTAK OIDC secrets exist) |
| `TAKSERVER_CoreConfig_OAuthServer_Name` | `cdk.json` → `takserver.branding` (only when WebTAK OIDC secrets exist) |
| `TAKSERVER_CoreConfig_OAuthServer_Scope`, `Issuer` | Hardcoded in `tak-server.ts` (only when WebTAK OIDC secrets exist) |
| `TAKSERVER_CoreConfig_OAuthServer_ClientId`, `RedirectUri`, `AuthEndpoint`, `TokenEndpoint`, `Secret` | Derived from the WebTAK OIDC Secrets Manager secret (only when WebTAK OIDC secrets exist) |

If `webtak.enableOidc` is not set (or the WebTAK OIDC secret doesn't exist),
CDK does not set the OAuth variables above, and the S3 file's OAuth settings
(if any) take effect normally.

`TAKSERVER_CoreConfig_OIDCDiscovery_*` (see below) is **not** touched by CDK
at all, in any configuration. It exists purely as an S3-config-file
mechanism for trusting a second OIDC provider (e.g. CloudTAK's own Authentik
application) alongside WebTAK's `<authServer>` entry, including its client
secret -- there is no cross-stack CDK wiring for it, by design, since
tak-infra has no way to resolve CloudTAK-owned values at deploy time and no
requirement to.

## Configuration Reference

Every variable below is actually read by `createCoreConfig.sh` via
`get_env_value`. Unless noted, setting the variable to an empty string or
leaving it unset causes the script to fall back to the XSD default listed.

### Network / Input

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_Network_Input_8089_Auth` | `x509` | `<input>` auth mode on the 8089 CoT port. Valid: `x509`, `ldap` |
| `TAKSERVER_CoreConfig_Network_Input_8089_AuthRequired` | `true` | When `true`, a connection on 8089 that does not present a valid credential (e.g. no client certificate) is hard-rejected at the socket level. When `false`, such a connection is silently admitted with no identity, gets zero groups (since `x509addAnonymous="false"`), and cannot exchange CoT with anyone — it just sits there accepted and archiving into the void. Note this default (`true`) differs from the CoreConfig XSD's own default (`false`); we override it here because the XSD default leaves an unauthenticated door open on 8089 |
| `TAKSERVER_CoreConfig_Network_Input_8089_Archive` | `true` | When `false`, CoTs received on 8089 are routed to connected clients only and not persisted to the database |
| `TAKSERVER_CoreConfig_Network_AlwaysArchiveMissionCot` | `false` | Always archive mission-related CoT messages, independent of the `Input_8089_Archive` setting above |

### Mission Settings

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_Network_MissionUseGroupsForContents` | `false` | When `true`, mission content inherits the mission's groups instead of the uploading user's groups |
| `TAKSERVER_CoreConfig_Network_MissionStrictUidMissionMembership` | `true` | Prevents mission map items from being added to other missions or broadcast outside the mission context |
| `TAKSERVER_CoreConfig_Network_MissionCreateGroupsRegex` | unset (no restriction) | Regex restricting which groups may create missions |
| `TAKSERVER_CoreConfig_Network_MissionDeleteRequiresOwner` | `false` | Limits mission deletion to users with the `MISSION_OWNER` role |
| `TAKSERVER_CoreConfig_Network_MissionAllowGroupChange` | `false` | Allows updating groups on an existing mission (and its content) |
| `TAKSERVER_CoreConfig_Network_MissionBrokerUidAddsFromApi` | `true` | Delivers mission map items to subscribers when added via the API service, not just via Messaging |
| `TAKSERVER_CoreConfig_Network_DisableBroadcastMapItems` | `false` | Disables broadcasting of map items to all subscribers |

### X.509 Group Cache (`<auth>`)

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_Auth_Default` | `ldap` | Default auth backend. Valid: `ldap`, `file` |
| `TAKSERVER_CoreConfig_Auth_X509useGroupCache` | `false` | Enables the X.509 group cache system, allowing certificate-authenticated users to have "active"/"inactive" groups |
| `TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive` | `false` | New users' first groups are marked "active" by default |

### LDAP Authentication (`<auth><ldap>`)

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix` | `cn=tak_` | LDAP group name prefix filter. **Overridden by CDK** if `ldapGroupPrefix` context is set — see [precedence table](#precedence-s3-file-vs-cdk-context) |
| `TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex` | `cn=tak_(.*?)(?:,\|$)` | Regex used to extract the group name from the LDAP group DN. Must literally start with `cn=` + `Groupprefix`'s text (a case-sensitive `String.startsWith()` on the raw config, not on what the regex matches) for TAK Server's `searchGroups()` to re-prepend the prefix before its exact-match group-description lookup — otherwise ATAK/CloudTAK clients never receive a description for that group. **Overridden by CDK** if `ldapGroupPrefix` context is set |
| `TAKSERVER_CoreConfig_Auth_LDAP_AdminGroup` | unset | LDAP group granted TAK Server admin rights |
| `TAKSERVER_CoreConfig_Auth_LDAP_EnableConnectionPool` | `false` | Enables LDAP connection pooling. **No-op with our `ldaps://` URL** unless the JVM system property `com.sun.jndi.ldap.connect.pool.protocol=plain ssl` is also set (the JDK's JNDI provider only pools non-SSL connections by default, and that system property can't be set via CoreConfig -- it requires a JVM `-D` flag). Left disabled to avoid implying pooling is active when it isn't; enabling it without the system property change accomplishes nothing |
| `TAKSERVER_CoreConfig_Auth_LDAP_ConnectionPoolTimeout` | `30000` | LDAP connection pool timeout, in milliseconds |
| `TAKSERVER_CoreConfig_Auth_LDAP_UserObjectClass` | `inetOrgPerson` | LDAP object class used to identify user entries during search |
| `TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass` | `groupOfNames` | LDAP object class used to identify group entries during search |
| `TAKSERVER_CoreConfig_Auth_LDAP_UserBaseRDN` | `ou=users,<LdapBaseDn>` | Fully-qualified user search base (see below — must NOT be relative) |
| `TAKSERVER_CoreConfig_Auth_LDAP_GroupBaseRDN` | `ou=groups,<LdapBaseDn>` | Fully-qualified group search base (see below — must NOT be relative) |

The `<ldap>` element's `url` attribute is built by CDK from `LdapsEndpoint` alone
(e.g. `ldaps://ldap.tak.nz:636`) and does **not** carry the base DN. Every
DN-shaped `<ldap>` attribute — `userstring`, `serviceAccountDN`, `userBaseRDN`,
`groupBaseRDN` — is instead fully qualified with the base DN (e.g.
`cn={username},ou=users,dc=ldap,dc=tak`, `ou=users,dc=ldap,dc=tak`).

**Do not put the base DN in the URL.** An earlier version of this setup built
the URL as `<LdapsEndpoint>/<LdapBaseDn>` with `userBaseRDN`/`groupBaseRDN` as
bare relative RDNs (`ou=users`, `ou=groups`). That combination looked
reasonable and passed `Test LDAP Connection` in the admin UI, but broke X.509
group lookups in production: TAK Server's `LdapAuthenticator.getGroupInfoByDN()`
takes the already-connected `DirContext` (whose JNDI namespace root is the
URL's base DN) and calls `ctx.lookup(fullyQualifiedUserDn)` using the
fully-qualified `userstring` value. `lookup()` resolves its argument *relative*
to the context's existing root, so with the base DN already baked into the
URL, the effective DN it tries to resolve doubles the base DN suffix and
matches nothing — silently returning zero groups, with no exception, for
every X.509/cert-authenticated connection (ATAK, CloudTAK, ETL data feeds).
`ctx.search()` (used by other paths, e.g. `searchGroups()`'s group-description
lookup) is not affected by this, which is why toggling individual settings in
isolation didn't reproduce or fix it — the break only shows up on the specific
`ctx.lookup()`-based path. Confirmed via a live JNDI reproduction (a small
standalone Java program using the same bind and `ctx.lookup()` call) run
directly against the production LDAP server, independent of TAK Server's own
code, during a live outage.

Every other `<ldap>` attribute (`url`, `userstring`, `serviceAccountDN`,
`serviceAccountCredential`, `style`, `nestedGroupLookup`, `callsignAttribute`,
`colorAttribute`, `roleAttribute`, `dnAttributeName`, `nameAttr`,
`ldapsTruststore*`, `updateinterval`) is hardcoded in the version templates
or derived directly from the CDK-provided `LDAP_DN`/`LDAP_SECURE_URL`/
`LDAP_Password` values. **There is no environment variable that overrides
any of these** — changing them requires editing the templates in
`docker-container/scripts/templates/`.

**`dnAttributeName` and `nameAttr` must be lowercase (`dn`, `cn`), not
uppercase (`DN`, `CN`).** LDAP attribute names are case-insensitive per
protocol and JNDI's `Attributes.get()` is documented as case-insensitive,
but TAK Server 5.8-RELEASE-65 was found in production to silently return
zero groups for every X.509/cert-authenticated connection (`group info for
<user> : {}`, no exception logged) when these were set to `DN`/`CN` against
our LDAP directory. Root-caused via a live DEBUG trace on the `messaging`
process during an outage where CoT was accepted and archived but never
routed to any subscriber, for every client type (ATAK, CloudTAK, ETL)
uniformly. Confirmed via isolation testing in the admin UI (reverting every
other diverged setting back to the broken values one at a time except
casing; only the casing remained different once the fix was isolated).
Suspected mechanism: an internal case-sensitive lookup of the returned
attribute map by the configured attribute name, though the exact code path
was not confirmed by decompilation.

### OAuth (`<auth><oauth>`)

The `<oauth>` element is only generated at all if
`TAKSERVER_CoreConfig_OAuthServer_Name` is set (directly, or by CDK when
WebTAK OIDC is enabled — see [precedence table](#precedence-s3-file-vs-cdk-context)).

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_OAuthServer_Name` | unset | Authorization server display name. Setting this triggers OAuth section generation |
| `TAKSERVER_CoreConfig_OAuthServer_Issuer` | empty | Path to the issuer's public key file |
| `TAKSERVER_CoreConfig_OAuthServer_ClientId` | empty | OAuth client ID |
| `TAKSERVER_CoreConfig_OAuthServer_Secret` | empty | OAuth client secret |
| `TAKSERVER_CoreConfig_OAuthServer_RedirectUri` | empty | OAuth redirect URI |
| `TAKSERVER_CoreConfig_OAuthServer_Scope` | empty | OAuth scopes to request |
| `TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint` | empty | Authorization endpoint URL |
| `TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint` | empty | Token endpoint URL |
| `TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts` | `false` | Disable TLS certificate validation for this OAuth server (development only) |
| `TAKSERVER_CoreConfig_OAuth_UsernameClaim` | `preferred_username` | JWT claim used as the username |

`TAKSERVER_CoreConfig_OAuthServer_JWKS` is used only by
`getOIDCIssuerPubKey.sh` (to download and write the file referenced by
`OAuthServer_Issuer`), not by `createCoreConfig.sh` directly.

### OIDC Discovery Trust (`<auth><oauth><openIdDiscoveryConfiguration>`)

A second, independent OIDC trust entry, resolved via a discovery document
(`.well-known/openid-configuration`) rather than a manually-configured
authorization/token endpoint pair. This is how TAK Server trusts bearer
tokens signed by a *second* OIDC provider/application in addition to the
`<authServer>` entry above -- e.g. CloudTAK has its own Authentik OIDC
application (separate from WebTAK's), and needs TAK Server to trust its
tokens for the `/Marti/api/tls/config` cert-enrollment M2M flow.

This element is only generated if `TAKSERVER_CoreConfig_OIDCDiscovery_Name`
is set. Unlike the WebTAK OAuth settings above, **none of these variables
are ever set by CDK** -- this is purely an S3 `takserver-config.env`
mechanism, including the client secret. Use it when running TAK Server with
CloudTAK and you want TAK Server to trust CloudTAK's own Authentik OIDC
application for its M2M cert-enrollment flow; leave it entirely unset when
running without CloudTAK. If neither `OAuthServer_Name` nor
`OIDCDiscovery_Name` is set, no `<oauth>` element is generated at all. If
only one is set, the `<oauth>` element contains just that one entry. Per
`CoreConfig.xsd`, `<authServer>` elements must precede
`<openIdDiscoveryConfiguration>` elements within `<oauth>` --
`createCoreConfig.sh` always emits them in that order regardless of which
env vars are set.

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_OIDCDiscovery_Name` | unset | Display name for this trust entry. Setting this triggers generation of the `<openIdDiscoveryConfiguration>` element |
| `TAKSERVER_CoreConfig_OIDCDiscovery_ClientId` | empty | OIDC client ID |
| `TAKSERVER_CoreConfig_OIDCDiscovery_Secret` | empty | OIDC client secret (required by the XSD even though it isn't exercised for bearer-token-only validation) |
| `TAKSERVER_CoreConfig_OIDCDiscovery_RedirectUri` | empty | Redirect URI (required by the XSD; not exercised unless TAK Server's own authorization-code flow is used against this provider) |
| `TAKSERVER_CoreConfig_OIDCDiscovery_ConfigurationUri` | empty | The provider's OIDC discovery document URI (`.../.well-known/openid-configuration`). TAK Server uses this to fetch the provider's live JWKS automatically |
| `TAKSERVER_CoreConfig_OIDCDiscovery_TrustAllCerts` | `false` | Disable TLS certificate validation for this provider (development only) |

`usernameClaim` (see the OAuth table above) is shared across both the
`<authServer>` and `<openIdDiscoveryConfiguration>` entries -- it's an
attribute of `<oauth>` itself, not per-provider.

### Federation

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_Federation_EnableFederation` | `true` | Enables/disables the `<federation>` element and federation-server sub-template. Also gates whether `<federation-server>` is generated at all |

All other `<federation>`/`<federation-server>` attributes are either
hardcoded in the version templates, or — once a `CoreConfig.xml` already
exists — are preserved verbatim rather than regenerated (see
[Configuration Persistence and Priority](#configuration-persistence-and-priority)).
There is no environment variable to change them on a fresh install; edit
`docker-container/scripts/templates/federation-server-*.xml` instead.

### Locate

The `<locate>` element is only created if `TAKSERVER_CoreConfig_Locate_Group`
is set.

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_Locate_Group` | unset | Group name. Setting this triggers `<locate>` element creation |
| `TAKSERVER_CoreConfig_Locate_Enabled` | `false` | Enable the Locate feature |
| `TAKSERVER_CoreConfig_Locate_RequireLogin` | `true` | Require login to use Locate |
| `TAKSERVER_CoreConfig_Locate_AddToMission` | `true` | Add Locate reports to a mission |
| `TAKSERVER_CoreConfig_Locate_Broadcast` | `true` | Broadcast Locate reports |
| `TAKSERVER_CoreConfig_Locate_CotType` | `a-f-G` | CoT type used for Locate reports |
| `TAKSERVER_CoreConfig_Locate_Mission` | unset | Mission name to add Locate reports to (only applied if set) |

### Optional Bare Elements

These elements are created (with no attributes) if their trigger variable is
set to any non-empty value. The variable's actual value is not used —
only its presence:

| Element | Trigger variable |
|---|---|
| `<vbm/>` | `TAKSERVER_CoreConfig_Vbm_Enabled` |
| `<plugins/>` | `TAKSERVER_CoreConfig_Plugins_UsePluginMessageQueue` |
| `<cluster/>` | `TAKSERVER_CoreConfig_Cluster_Enabled` |
| `<docs/>` | `TAKSERVER_CoreConfig_Docs_AdminOnly` |
| `<logging/>` | `TAKSERVER_CoreConfig_Logging_JsonFormatEnabled` |

Note: all five of these elements are already present, unconditionally, in
every version template (`coreconfig-5.4/5.5/5.6.xml`) — so in practice this
logic only matters if a template is edited to remove one of them.

### CA Certificate Settings (separate mechanism)

These are **not** read by `createCoreConfig.sh`. They are consumed by
`docker-container/scripts/start-tak.sh` during initial self-signed
certificate generation (first boot only, when no `ca.pem` exists yet):

| Variable | Default |
|---|---|
| `TAKSERVER_CACert_Country` | `NZ` |
| `TAKSERVER_CACert_State` | `Wellington` |
| `TAKSERVER_CACert_City` | `Wellington` |
| `TAKSERVER_CACert_Org` | `TAK.NZ` |
| `TAKSERVER_CACert_OrgUnit` | `TAK.NZ Operations` |

## Configuration Methods

### S3 Configuration File

For production deployments, TAK Server can load configuration from an S3
bucket (imported from BaseInfra). Upload a `takserver-config.env` file to the
S3 configuration bucket to provide environment variables.

**Example**: See `takserver-config.env.example` in the repository root.

**Usage**:
1. Copy `takserver-config.env.example` to `takserver-config.env`
2. Customize using only the variables listed in [Configuration Reference](#configuration-reference) above
3. Upload to the S3 bucket: `s3://{bucket-name}/takserver-config.env`
4. Enable S3 configuration in deployment: `useS3TAKServerConfigFile=true`

### CDK Context

Some settings are controlled exclusively via CDK context rather than the S3
file — see the [precedence table](#precedence-s3-file-vs-cdk-context) above.

## Adding a New Setting

If you need a `CoreConfig.xml` attribute that isn't in the
[Configuration Reference](#configuration-reference), it must be wired up in
`docker-container/scripts/createCoreConfig.sh` before an environment variable
will have any effect. The two supported patterns:

1. **Template placeholder** (for values baked into the initial render):
   add `{{PLACEHOLDER}}` to the relevant attribute in
   `docker-container/scripts/templates/coreconfig-*.xml`, then add a
   `-e "s|{{PLACEHOLDER}}|$(get_env_value "TAKSERVER_CoreConfig_..." "default" "type")|g"`
   line to `substitute_template()`.
2. **Force-apply after templating** (for values that also need to work when
   the attribute might not already exist, e.g. most `<network>` attributes):
   add a `get_env_value`/`safe_xml_update` pair after the "Applying CDK
   environment variable overrides" comment, following the existing examples
   for `MissionUseGroupsForContents` etc.

After adding either, update this document and add a case to
`test/CoreConfig/test-createCoreConfig.sh`, then run
`bash test/CoreConfig/test-createCoreConfig.sh` to confirm the change
produces valid XML.

## Best Practices

- **Verify a setting is real before relying on it.** Check the
  [Configuration Reference](#configuration-reference) above, or search
  `createCoreConfig.sh` for `get_env_value "TAKSERVER_CoreConfig_YourSetting"`
  directly — if it's not there, the variable does nothing.
- **Check CDK precedence.** Before debugging why an S3 value "isn't working,"
  check the [precedence table](#precedence-s3-file-vs-cdk-context) — several
  common settings are always overridden by CDK context.
- Store sensitive values (passwords, secrets) in Secrets Manager rather than
  the S3 config file where practical.
- After changing `takserver-config.env`, you must force a new ECS deployment
  (not just restart an existing task) for the change to take effect — ECS
  fetches `environmentFiles` from S3 at task **creation** time, not at
  container start.

## Troubleshooting

### Common Issues

**Environment variable seems to have no effect**
- Confirm the variable is listed in [Configuration Reference](#configuration-reference) — most `TAKSERVER_CoreConfig_*` names that look plausible are not actually wired up
- Check the [precedence table](#precedence-s3-file-vs-cdk-context) — CDK context may be silently overriding your S3 value
- Confirm you forced a new ECS deployment after updating the S3 file (see Best Practices above)

**Configuration not applied / XSD validation failure at container start**
- Check `createCoreConfig.sh`'s stdout in the container logs — it logs every setting it applies and any XSD validation errors in detail
- Run `bash test/CoreConfig/test-createCoreConfig.sh` locally to reproduce validation issues outside the container

**A setting made via the admin UI keeps reverting**
- Expected, for everything except `<federation>` — see [Configuration Persistence and Priority](#configuration-persistence-and-priority)

### Debug Commands

```bash
# Check environment variables available to the container
env | grep TAKSERVER_CoreConfig

# Validate generated XML against the schema
xmllint --schema /opt/tak/CoreConfig.xsd --noout /opt/tak/CoreConfig.xml

# Re-run the generator manually inside the container to see full output
/opt/tak/scripts/createCoreConfig.sh /opt/tak/persistent-config/CoreConfig.xml
```
