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

## Configuration Reference

Every variable below is actually read by `createCoreConfig.sh` via
`get_env_value`. Unless noted, setting the variable to an empty string or
leaving it unset causes the script to fall back to the XSD default listed.

### Network / Input

| Variable | Default | Effect |
|---|---|---|
| `TAKSERVER_CoreConfig_Network_Input_8089_Auth` | `x509` | `<input>` auth mode on the 8089 CoT port. Valid: `x509`, `ldap` |
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
| `TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex` | `cn=tak_(.*)` | Regex used to extract the group name from the LDAP group DN. **Overridden by CDK** if `ldapGroupPrefix` context is set |
| `TAKSERVER_CoreConfig_Auth_LDAP_AdminGroup` | unset | LDAP group granted TAK Server admin rights |
| `TAKSERVER_CoreConfig_Auth_LDAP_EnableConnectionPool` | `false` | Enables LDAP connection pooling |

Every other `<ldap>` attribute (`url`, `userstring`, `serviceAccountDN`,
`serviceAccountCredential`, `groupBaseRDN`, `userBaseRDN`, `style`,
`groupObjectClass`, `nestedGroupLookup`, `callsignAttribute`,
`colorAttribute`, `roleAttribute`, `dnAttributeName`, `nameAttr`,
`ldapsTruststore*`, `updateinterval`) is hardcoded in the version templates
or derived directly from the CDK-provided `LDAP_DN`/`LDAP_SECURE_URL`/
`LDAP_Password` values. **There is no environment variable that overrides
any of these** — changing them requires editing the templates in
`docker-container/scripts/templates/`.

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
