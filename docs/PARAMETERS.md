# Configuration Management Guide

The TAK Server Infrastructure uses **AWS CDK context-based configuration** with centralized settings in [`cdk.json`](../cdk.json). This provides a single source of truth for all environment configurations while supporting runtime overrides.

## Quick Configuration Reference

### **Environment-Specific Deployment**
```bash
# Deploy with default configuration
npm run deploy:dev     # Development environment
npm run deploy:prod    # Production environment

# Deploy with configuration overrides
npm run deploy:dev -- --context hostname=ops
npm run deploy:prod -- --context instanceClass=db.t4g.large
```

## Configuration System Architecture

### **Context-Based Configuration**
All configurations are stored in [`cdk.json`](../cdk.json) under the `context` section:

```json
{
  "context": {
    "dev-test": {
      "stackName": "Dev",
      "database": {
        "instanceClass": "db.t4g.large",
        "instanceCount": 1,
        "engineVersion": "18.3",
        "allocatedStorage": 20,
        "maxAllocatedStorage": 100,
        "enablePerformanceInsights": false,
        "monitoringInterval": 0,
        "backupRetentionDays": 7,
        "deleteProtection": false,
        "ioOptimized": true
      },
      "ecs": {
        "taskCpu": 2048,
        "taskMemory": 4096,
        "desiredCount": 1,
        "enableDetailedLogging": true,
        "enableEcsExec": true
      },
      "takserver": {
        "hostname": "tak",
        "servicename": "ops",
        "branding": "tak-nz",
        "version": "5.8-RELEASE-103",
        "useS3TAKServerConfigFile": false,
        "letsEncryptMode": "staging",
        "letsEncryptEmail": "admin@tak.nz",
        "enableFederation": true,
        "enableCloudWatchMetrics": false
      },
      "ecr": {
        "imageRetentionCount": 5,
        "scanOnPush": false
      },
      "general": {
        "removalPolicy": "DESTROY",
        "enableDetailedLogging": true,
        "enableContainerInsights": false
      }
    },
    "prod": {
      "stackName": "Prod",
      "database": {
        "instanceClass": "db.t4g.large",
        "instanceCount": 2,
        "engineVersion": "18.3",
        "allocatedStorage": 100,
        "maxAllocatedStorage": 1000,
        "enablePerformanceInsights": true,
        "monitoringInterval": 60,
        "backupRetentionDays": 30,
        "deleteProtection": true
      },
      "ecs": {
        "taskCpu": 4096,
        "taskMemory": 8192,
        "desiredCount": 2,
        "enableDetailedLogging": false,
        "enableEcsExec": false
      },
      "takserver": {
        "hostname": "tak",
        "servicename": "ops",
        "branding": "tak-nz",
        "version": "5.8-RELEASE-103",
        "useS3TAKServerConfigFile": true,
        "letsEncryptMode": "production",
        "letsEncryptEmail": "admin@tak.nz",
        "enableFederation": true,
        "enableCloudWatchMetrics": false
      },
      "ecr": {
        "imageRetentionCount": 20,
        "scanOnPush": true
      },
      "general": {
        "removalPolicy": "RETAIN",
        "enableDetailedLogging": false,
        "enableContainerInsights": true
      }
    }
  }
}
```

### **Environment Comparison**

| Environment | Stack Name | Description |
|-------------|------------|-------------|
| `dev-test` | `TAK-Dev-TakInfra` | Cost-optimized development |
| `prod` | `TAK-Prod-TakInfra` | High-availability production |

### **Key Configuration Differences**

| Setting | dev-test | prod | Impact |
|---------|----------|------|--------|
| **Database Instance** | `db.serverless` (Aurora Serverless v2) | `db.t4g.large` (2 instances) | High availability |
| **Database Storage** | `20GB` initial, `100GB` max | `100GB` initial, `1000GB` max | Storage capacity |
| **Performance Insights** | `false` | `true` | Database monitoring |
| **ECS Resources** | `2048 CPU, 4096 MB` | `4096 CPU, 8192 MB` | Performance |
| **ECS Tasks** | `1` task | `1` task | Same task count |
| **ECS Exec** | `true` (debugging) | `false` (security) | Development access |
| **Container Insights** | `false` | `true` | ECS monitoring |
| **S3 Config File** | `false` | `true` | Advanced configuration |
| **ECR Image Retention** | `5` images | `20` images | Image history |
| **ECR Vulnerability Scanning** | `false` | `true` | Security scanning |
| **Removal Policy** | `DESTROY` | `RETAIN` | Resource cleanup |

---

## **Runtime Configuration Overrides**

Use CDK's built-in `--context` flag with **flat parameter names** to override any configuration value. The actual implementation uses flat parameters, not dot notation:

### **Database Configuration**
| Parameter | Description | dev-test | prod |
|-----------|-------------|----------|------|
| `instanceClass` | RDS instance class (see the database notes below) | `db.t4g.large` | `db.t4g.large` |
| `instanceCount` | Number of database instances | `1` | `2` |
| `engineVersion` | PostgreSQL engine version | `18.3` | `18.3` |
| `allocatedStorage` | Initial storage allocation (GB) | `20` | `100` |
| `maxAllocatedStorage` | Maximum storage allocation (GB) | `100` | `1000` |
| `enablePerformanceInsights` | Enable performance insights | `false` | `true` |
| `monitoringInterval` | Enhanced monitoring interval (seconds) | `0` | `60` |
| `backupRetentionDays` | Backup retention period (days) | `7` | `30` |
| `deleteProtection` | Enable deletion protection | `false` | `true` |
| `enableCloudWatchLogs` | Enable CloudWatch logs exports | `false` | `false` |
| `ioOptimized` | Aurora storage type: `true` = I/O-Optimized, `false` = Standard, unset = leave the cluster as it is | `true` | unset |

**Database notes**
- **`instanceClass`:** `db.serverless` selects Aurora Serverless v2 (capacity from `serverlessV2MinCapacity` and `serverlessV2MaxCapacity`). Provisioned classes accepted exactly: `db.t4g.medium`, `db.t4g.large`, and `db.r6g.*`, `db.r7g.*`, `db.r8g.*` from `large` up. Any other value falls back to `db.t4g.large` (if it contains "large") or `db.t4g.medium`, and `cdk synth` prints a warning saying so.
- **RDS Data API:** switched off on provisioned clusters (`enableDataApi: false`). AWS does not support it on T-class instances, and a cluster that had it enabled while it was Serverless v2 makes the instance-class change fail and roll back. Nothing in this stack uses it.
- **`ioOptimized`:** unset sends nothing to CloudFormation, so an existing cluster keeps its storage type (the prod profile leaves it unset). AWS only allows moving from I/O-Optimized back to Standard once every 30 days, so keep it the same across every deploy of a stack. The Demo pipeline passes `ioOptimized=true` for both its prod window and its revert for that reason.
- **Moving a cluster from `db.serverless` to a provisioned class** restarts the writer (a short outage). Watch `FreeableMemory` and `CPUCreditBalance` for a day or two afterwards.

### **ECS Configuration**
| Parameter | Description | dev-test | prod |
|-----------|-------------|----------|------|
| `taskCpu` | CPU units for ECS tasks | `2048` | `4096` |
| `taskMemory` | Memory (MB) for ECS tasks | `4096` | `8192` |
| `desiredCount` | Desired number of running tasks | `1` | `1` |
| `enableDetailedLogging` | Enable detailed application logging | `true` | `false` |
| `enableEcsExec` | Enable ECS exec for debugging | `true` | `false` |

### **TAK Server Configuration**
| Parameter | Description | dev-test | prod |
|-----------|-------------|----------|------|
| `hostname` | Hostname for TAK Server service | `tak` | `tak` |
| `servicename` | Service name for TAK Server | `ops` | `ops` |
| `branding` | Docker image branding variant | `tak-nz` | `tak-nz` |
| `version` | TAK Server version | `5.8-RELEASE-103` | `5.8-RELEASE-103` |
| `useS3TAKServerConfigFile` | Use S3 configuration file | `false` | `true` |
| `letsEncryptMode` | Let's Encrypt certificate mode | `staging` | `production` |
| `letsEncryptEmail` | Let's Encrypt email address | `admin@tak.nz` | `admin@tak.nz` |
| `enableFederation` | Enable TAK federation | `true` | `true` |
| `enableCloudWatchMetrics` | Export TAK Server API (Micrometer) metrics to CloudWatch. Off by default: about 600 billed custom metrics and no alarm or dashboard uses them. The API JVM keeps its Netty TLS workaround (`docker/tak-server/patch-jvm-flags.py`), so turning this back on works without other changes | `false` | `false` |

### **ECR Configuration**
| Parameter | Description | dev-test | prod |
|-----------|-------------|----------|------|
| `imageRetentionCount` | Number of ECR images to retain | `5` | `20` |
| `scanOnPush` | Enable ECR vulnerability scanning | `false` | `true` |

### **General Configuration**
| Parameter | Description | dev-test | prod |
|-----------|-------------|----------|------|
| `removalPolicy` | Resource cleanup policy | `DESTROY` | `RETAIN` |
| `enableDetailedLogging` | Enable detailed CloudWatch logging | `true` | `false` |
| `enableContainerInsights` | Enable ECS Container Insights | `false` | `true` |

### **Bedrock Knowledge Base Configuration**
| Parameter | Description | dev-test | prod |
|-----------|-------------|----------|------|
| `bedrock.knowledgeBases` | Names of the TAK-GPT Bedrock knowledge bases to create (S3 Vectors storage). Each name is also the folder the documents are read from: `bedrock-kb/<name>/` in the BaseInfra TAK Images bucket | `["nema-cdem"]` | `["nema-cdem"]` |

- Override on the command line with a comma-separated list: `--context bedrockKnowledgeBases=nema-cdem,nzdf`. An empty value (`--context bedrockKnowledgeBases=`) creates none.
- Names use 3 to 63 lower-case letters, digits and hyphens.
- In a region without Bedrock Knowledge Bases (today `ap-southeast-6`, Auckland; the list is `BEDROCK_KB_UNSUPPORTED_REGIONS` in `lib/utils/constants.ts`) the stack creates none and prints a synth warning. Set the list to `[]` to silence the warning. The TAK-GPT bot then needs an agent in a supported region: set the bot's `region`, for example `ap-southeast-2`.
- The stack creates the vector index, the knowledge base role, the knowledge base (named `<name>-s3v`) and its S3 data source, and outputs the IDs as `BedrockKb<Name>Id` and `BedrockKb<Name>DataSourceId` (`nema-cdem` becomes `NemaCdem`). `scripts/bedrock/setup-bedrock-agent.py` reads them. Ingesting documents is not stack state: see `scripts/bedrock/README.md`.

### **KMS CA Keys**
| Parameter | Description | Default |
|-----------|-------------|---------|
| `pki.kmsCa.enabled` | The first-boot PKI with the Root CA and Intermediate CA signing keys in AWS KMS (#136). Off keeps the old PKI of the TAK Server scripts (no rotation) and creates nothing. A stack with an old PKI keeps it until `pki-legacy-reset.sh` ([CERT_ROTATION.md](CERT_ROTATION.md#moving-a-stack-with-the-old-pki-to-the-new-one)). To deploy a stack that must stay on the old PKI, pass `--context pkiKmsCaEnabled=false` on every command | `true` in `dev-test` and `prod` |
| `pki.kmsCa.environmentLabel` | Environment label in CA names and key aliases, for example `Try` gives `TAK.NZ Try Root CA 01` and `alias/tak-nz-try-root-ca-01`. 1 to 24 letters, digits, spaces or hyphens. It is part of the CA names, so keep it on every deploy of a stack and never change it. Set it when it is not the stack name. The stack output `PkiEnvironmentLabel` shows it. A deploy with another label fails: `pki-bootstrap.sh` refuses to start the new task, the old one keeps running and the deployment rolls back | the stack name (`Prod`, `Dev`, or `--context stackName`) |
| `pki.kmsCa.rootCaNumbers` | Root CA key generations to create. Generation 2 exists from the start as the spare for the next rotation; after a rotation uses it, add the next number (the alarm `RotationSpareKeyMissing` says so) | `[1, 2]` |
| `pki.kmsCa.intermediateCaNumbers` | Intermediate CA key generations to create (spare generation 2 from the start, as for the Root CA) | `[1, 2]` |
| `pki.kmsCa.alertEmail` | Email address for the certificate alert and critical topics (every Root CA signature, expiry warnings, failed rotations) | none |
| `pki.kmsCa.infoEmail` | Email address for the certificate info topic (a rotation step happened) | none |
| `pki.kmsCa.validity.rootDays` / `intermediateDays` / `enrollmentCaDays` / `serverCertDays` / `adminCertDays` | Validity of the first-boot PKI in days (#189). A certificate must not outlive its issuer | 7300 / 3650 / 1095 / 365 / 365 |
| `pki.kmsCa.validity.adminCertRenewDays` / `adminCertGraceDays` | The admin certificate is rotated when this many days or fewer are left (must be smaller than `adminCertDays`), and the copies of the previous admin key are deleted this many days after a rotation (#132) | 60 / 7 |
| `pki.kmsCa.rotation.clientCertDays` / `bufferDays` | Validity of client certificates (the `validityDays` of TAK Server's CA configuration) and the safety buffer. W = both added is the window that every phone gets to receive a certificate from a new chain (#171) | 365 / 90 |
| `pki.kmsCa.rotation.enrollmentCaRotationDays` | The Enrollment CA is replaced when it is this many days old. Its validity must cover this plus W (checked at synth) | 365 |
| `pki.kmsCa.rotation.requireApproval` | Steps that wait for `pki-rotate.sh approve <scenario> <step>` (`bridge`, `cut`, `retire`, `switch`); an empty list switches approvals off. `cut` cuts off the phones that the coverage check cannot see (a hand-made data package), `retire` destroys keys | `["cut", "retire"]`; `cdk.json` sets `["cut"]` in `prod` and `[]` in `dev-test` |
| `pki.kmsCa.validity.serverCertRenewDays` | The server certificate is rotated when this many days or fewer are left (#131). Must be smaller than `serverCertDays` | 60 |
| `pki.kmsCa.p12Profile` | PKCS#12 profile of the user-facing p12 files: `compat3des` (3DES, SHA-1 MAC) or `aes256` | `compat3des` |
- Command line: `--context pkiKmsCaEnabled=false` (old PKI) or `--context pkiEnvironmentLabel=Try`, plus `pkiRootCaNumbers=1,2`, `pkiIntermediateCaNumbers=1,2`, `pkiAlertEmail=...`, `pkiInfoEmail=...`, `pkiP12Profile=aes256` and `pkiRootDays`, `pkiIntermediateDays`, `pkiEnrollmentCaDays`, `pkiServerCertDays`, `pkiAdminCertDays`, `pkiServerCertRenewDays`, `pkiAdminCertRenewDays`, `pkiAdminCertGraceDays`, `pkiClientCertDays`, `pkiRotationBufferDays`, `pkiEnrollmentCaRotationDays`, `pkiRotationRequireApproval` (comma separated).
- The keys are never deleted by CloudFormation. The Root CA signing alert needs a CloudTrail trail that logs read and write management events; BaseInfra creates one by default (`cloudTrail.enabled`). See [KMS_CA_KEYS.md](KMS_CA_KEYS.md).

### **WebTAK OIDC Configuration**
| Parameter | Description | dev-test | prod |
|-----------|-------------|----------|------|
| `enableOidc` | Enable WebTAK OIDC integration | `true` | `true` |
| `providerName` | OIDC provider name in Authentik | `TAK-WebTAK` | `TAK-WebTAK` |
| `applicationName` | Application name in Authentik | `WebTAK` | `WebTAK` |
| `applicationSlug` | Application slug for URLs | `tak-webtak` | `tak-webtak` |
| `useTakServerLoginPage` | Use TAK Server login page | `false` | `false` |
| `openInNewTab` | Open application in new tab | `true` | `true` |
| `authenticationFlowName` | Authentik authentication flow | `""` | `""` |
| `authorizationFlowName` | Authentik authorization flow | `default-provider-authorization-implicit-consent` | `default-provider-authorization-implicit-consent` |
| `invalidationFlowName` | Authentik invalidation flow | `default-provider-invalidation-flow` | `default-provider-invalidation-flow` |
| `groupName` | LDAP group for WebTAK access | `Team Awareness Kit` | `Team Awareness Kit` |
| `description` | Application description | `Web-based geospatial collaboration platform (Legacy system).` | `Web-based geospatial collaboration platform (Legacy system).` |
| `iconPath` | Path to application icon | `src/webtak-oidc-setup/tak-logo.png` | `src/webtak-oidc-setup/tak-logo.png` |
| `signingKeyName` | Authentik signing key name | `authentik Self-signed Certificate` | `authentik Self-signed Certificate` |

---

## **Security Considerations**

### **Network Security**
- **Private Subnets**: All compute resources deployed in private subnets
- **Security Groups**: Restrictive access controls with least privilege
- **Load Balancers**: Network Load Balancer for TAK protocols
- **VPC Integration**: Imports VPC and subnets from base infrastructure

### **Data Security**
- **Database Encryption**: Aurora PostgreSQL encrypted with KMS
- **Secrets Management**: AWS Secrets Manager for all sensitive data
- **EFS Encryption**: Encrypted file system for persistent storage
- **Certificate Management**: Automated Let's Encrypt certificate handling

### **Access Control**
- **IAM Roles**: Service-specific roles with minimal permissions
- **ECS Exec**: Enabled in development, disabled in production
- **LDAP Integration**: Secure LDAP authentication with AuthInfra

---

## **Cost Optimization**

### **Development Environment Optimizations**
- **Aurora Serverless v2**: Pay-per-use database scaling
- **Single ECS Task**: Minimal compute allocation
- **No Performance Insights**: Reduces database monitoring costs
- **Container Insights Disabled**: Reduces CloudWatch costs

### **Production Environment Features**
- **High Availability**: Multi-AZ database and ECS deployment
- **Enhanced Security**: Full encryption, vulnerability scanning
- **Performance Monitoring**: Performance Insights, Container Insights
- **Advanced Configuration**: S3-based TAK Server configuration
- **Image Management**: Extended ECR retention, vulnerability scanning

---

## **Troubleshooting Configuration**

### **Common Configuration Issues**

#### **Invalid Database Instance Class**
```
Error: Invalid instance class: db.invalid.type
```
**Solution**: Use valid RDS instance types (e.g., `db.t4g.micro`, `db.t4g.small`, `db.t4g.large`, `db.serverless`)

#### **Invalid ECS CPU/Memory Combination**
```
Error: Invalid CPU/memory combination
```
**Solution**: Use valid Fargate combinations (2048/4096, 4096/8192, etc.)

#### **Missing TAK Server Version**
```
Error: TAK Server version is required
```
**Solution**: Provide TAK Server version in context configuration

### **Configuration Validation**
```bash
# Preview configuration before deployment
npm run synth:dev
npm run synth:prod

# Validate specific overrides
npm run synth:dev -- --context instanceClass=db.t4g.medium
```

### **Parameter Override Examples**
```bash
# Custom TAK Server hostname
npm run deploy:dev -- --context hostname=ops

# Database scaling
npm run deploy:dev -- --context instanceClass=db.t4g.medium

# Enable production features in development
npm run deploy:dev -- \
  --context enablePerformanceInsights=true \
  --context enableContainerInsights=true

# Custom stack name
npm run deploy:dev -- --context stackName=Demo

# Override ECS resources
npm run deploy:dev -- \
  --context taskCpu=4096 \
  --context taskMemory=8192 \
  --context desiredCount=2

# Enable S3 configuration in development
npm run deploy:dev -- --context useS3TAKServerConfigFile=true

# Custom branding and version
npm run deploy:prod -- \
  --context branding=generic \
  --context version=5.5-RELEASE-1
```

### **Override Syntax Rules**
- Use **flat parameter names**: `instanceClass=value` (NOT `database.instanceClass=value`)
- **Command-line context always takes precedence** over `cdk.json` values
- Can override **any configuration property** defined in the environment config
- Boolean values: `true`/`false` (not `True`/`False`)
- Numeric values: Raw numbers (not quoted)

---

## **Stack Naming and Tagging**

### **Stack Names**
- **dev-test**: `TAK-Dev-TakInfra`  
- **prod**: `TAK-Prod-TakInfra`

### **Custom Stack Names**
```bash
# Results in "TAK-Staging-TakInfra"
npm run deploy:prod -- --context stackName=Staging

# Results in "TAK-Demo-TakInfra"  
npm run deploy:dev -- --context stackName=Demo
```

### **Resource Tagging**
All AWS resources are automatically tagged with:
- **Project**: "TAK.NZ" (from `tak-defaults.project` or `tak-project` override)
- **Component**: "BaseInfra" (from `tak-defaults.component` or `tak-component` override)
- **Environment**: The environment name (from `stackName`)
- **ManagedBy**: "CDK"

### **Project Configuration Overrides**
The project metadata can be overridden using individual context parameters:

```bash
# Override project name for custom branding
npm run deploy:dev -- --context tak-project="Custom TAK Project"

# Override component name (useful for custom deployments)
npm run deploy:dev -- --context tak-component="CustomBaseInfra"

# Override region for tagging purposes
npm run deploy:dev -- --context tak-region="us-east-1"
```

#### **Project Context Parameters**
| Parameter | Description | Default | Example Override |
|-----------|-------------|---------|------------------|
| `tak-project` | Project name for resource tagging | `TAK.NZ` | `"Enterprise TAK"` |
| `tak-component` | Component name for resource tagging | `BaseInfra` | `"CustomBaseInfra"` |
| `tak-region` | Region identifier for tagging | `ap-southeast-2` | `"us-west-2"` |

---

## **Complete Configuration Reference**

### **Required Parameters**
| Parameter | Description | Example |
|-----------|-------------|---------|
| `stackName` | Stack identifier for CloudFormation exports | `Dev`, `Prod`, `Demo` |

### **Database Configuration**
| Parameter | Type | Description | Valid Values |
|-----------|------|-------------|-------------|
| `instanceClass` | string | RDS instance class | `db.serverless`, `db.t4g.medium`, `db.t4g.large`, `db.r6g.large` and up (also `db.r7g.*`, `db.r8g.*`) |
| `instanceCount` | number | Number of database instances | `1`, `2` |
| `engineVersion` | string | PostgreSQL engine version | `18.3` |
| `allocatedStorage` | number | Initial storage allocation (GB) | `20-65536` |
| `maxAllocatedStorage` | number | Maximum storage allocation (GB) | `100-65536` |
| `enablePerformanceInsights` | boolean | Enable performance insights | `true`, `false` |
| `monitoringInterval` | number | Enhanced monitoring interval (seconds) | `0`, `15`, `30`, `60` |
| `backupRetentionDays` | number | Backup retention period (days) | `1-35` |
| `deleteProtection` | boolean | Enable deletion protection | `true`, `false` |
| `enableCloudWatchLogs` | boolean | Enable CloudWatch logs exports | `true`, `false` |
| `ioOptimized` | boolean | Aurora I/O-Optimized storage; unset leaves the cluster unchanged | `true`, `false`, unset |

### **ECS Configuration**
| Parameter | Type | Description | Valid Values |
|-----------|------|-------------|-------------|
| `taskCpu` | number | CPU units for ECS tasks | `256`, `512`, `1024`, `2048`, `4096` |
| `taskMemory` | number | Memory (MB) for ECS tasks | `512`, `1024`, `2048`, `4096`, `8192` |
| `desiredCount` | number | Desired number of running tasks | `1-10` |
| `enableDetailedLogging` | boolean | Enable detailed application logging | `true`, `false` |
| `enableEcsExec` | boolean | Enable ECS exec for debugging | `true`, `false` |

### **TAK Server Configuration**
| Parameter | Type | Description | Valid Values |
|-----------|------|-------------|-------------|
| `hostname` | string | TAK Server hostname | Any valid hostname |
| `servicename` | string | TAK Service name | Any valid hostname |
| `branding` | string | Docker image branding | `tak-nz`, `generic` |
| `version` | string | TAK Server version | `5.8-RELEASE-103`, etc. |
| `useS3TAKServerConfigFile` | boolean | Use S3 configuration file | `true`, `false` |
| `letsEncryptMode` | string | Let's Encrypt mode | `staging`, `production` |
| `letsEncryptEmail` | string | Let's Encrypt email | Valid email address |
| `enableFederation` | boolean | Enable TAK federation | `true`, `false` |
| `enableCloudWatchMetrics` | boolean | Enable CloudWatch metrics | `true`, `false` |

### **Bedrock Configuration**
| Parameter | Type | Description | Valid Values |
|-----------|------|-------------|-------------|
| `bedrock.knowledgeBases` | string[] | Knowledge bases to create; override with `bedrockKnowledgeBases` (comma-separated) | Names of 3 to 63 lower-case letters, digits, hyphens |

## 📋 Deployment Examples

### Basic Deployments
```bash
# Development environment
npm run deploy:dev

# Production environment
npm run deploy:prod
```

### Advanced Deployments
```bash
# Production with custom domain
npm run deploy:prod -- --context r53ZoneName=company.com

# Development with production-like database
npm run deploy:dev -- \
  --context instanceClass=db.t4g.medium \
  --context enablePerformanceInsights=true

# Custom environment for feature testing
npm run deploy:dev -- \
  --context stackName=FeatureX \
  --context r53ZoneName=feature.tak.nz

# High-performance development environment
npm run deploy:dev -- \
  --context taskCpu=4096 \
  --context taskMemory=8192 \
  --context desiredCount=2
```

### Environment-Specific Overrides
```bash
# Development with enhanced security
npm run deploy:dev -- \
  --context deleteProtection=true \
  --context enablePerformanceInsights=true

# Production with cost optimization
npm run deploy:prod -- \
  --context instanceCount=1 \
  --context desiredCount=1

# Custom TAK Server configuration
npm run deploy:dev -- \
  --context hostname=ops \
  --context servicename=tak \
  --context version=5.5-RELEASE-1
```

## Required Environment Variables

```bash
# Set AWS credentials and region
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export CDK_DEFAULT_REGION=$(aws configure get region || echo "ap-southeast-2")

# Deploy with environment variables set
npm run deploy:prod
```

### Using AWS Profiles
```bash
# Set profile-specific environment variables
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text --profile your-profile)
export CDK_DEFAULT_REGION=$(aws configure get region --profile your-profile)

# Deploy using specific profile
AWS_PROFILE=your-profile npm run deploy:prod
```