# 🚀 TAK Server Infrastructure - Deployment Guide

## **Quick Start (Recommended)**

### **Prerequisites**
- AWS Account with configured credentials
- Base infrastructure stack (`TAK-<n>-BaseInfra`) deployed
- Authentication infrastructure stack (`TAK-<n>-AuthInfra`) deployed
- Public Route 53 hosted zone for your domain
- Node.js 18+ and npm installed
- Development tools (see [Development Environment Setup](#development-environment-setup) below)

### **One-Command Deployment**
```bash
# Install dependencies
npm install

# Deploy development environment
npm run deploy:dev

# Deploy production environment  
npm run deploy:prod
```

**That's it!** 🎉 The enhanced npm scripts handle building, context configuration, and deployment.

---

## **📋 Environment Configurations**

| Environment | Stack Name | Domain | TAK Infra Cost* | Complete Stack Cost** | Features |
|-------------|------------|--------|----------------|----------------------|----------|
| **dev-test** | `TAK-Dev-TakInfra` | `tak.dev.tak.nz` | ~$91 | ~$220 | Cost-optimized, Aurora Serverless v2 |
| **prod** | `TAK-Prod-TakInfra` | `tak.tak.nz` | ~$390 | ~$778 | High availability, multi-AZ deployment |

*TAK Server Infrastructure only, **Complete deployment (BaseInfra + AuthInfra + TakInfra)  
Estimated AWS costs for ap-southeast-2, excluding data transfer and usage

---

## **🔧 Advanced Configuration**

### **Custom Stack Deployment**
```bash
# Deploy with custom stack name
npm run deploy:dev -- --context stackName=Demo
npm run deploy:prod -- --context stackName=Enterprise
```

### **Database Configuration Overrides**
```bash
# Custom database settings
npm run deploy:dev -- --context instanceClass=db.t4g.small
npm run deploy:prod -- --context instanceCount=1

# TAK Server configuration
npm run deploy:dev -- --context hostname=ops
npm run deploy:dev -- --context version=5.5-RELEASE-1
```

### **Infrastructure Preview**
```bash
# Preview changes before deployment
npm run synth:dev     # Development environment
npm run synth:prod    # Production environment

# Show what would change
npm run cdk:diff:dev  # Development diff
npm run cdk:diff:prod # Production diff
```

---

## **⚙️ Configuration System Deep Dive**

### **Environment Configuration Structure**
All settings are stored in [`cdk.json`](../cdk.json) under the `context` section:

```json
{
  "context": {
    "dev-test": {
      "stackName": "Dev",
      "database": {
        "instanceClass": "db.serverless",
        "instanceCount": 1
      },
      "takserver": {
        "hostname": "tak",
        "servicename": "ops",
        "version": "5.4-RELEASE-19"
      }
    }
  }
}
```

### **Runtime Configuration Overrides**
Override any configuration value using CDK's built-in `--context` flag:

```bash
# Custom TAK Server hostname
npm run deploy:dev -- --context hostname=ops

# Database scaling
npm run deploy:dev -- --context instanceClass=db.t4g.small

# Enable S3 configuration file
npm run deploy:dev -- --context useS3TAKServerConfigFile=true
```

---

## **🚀 First-Time Setup**

### **Prerequisites**
1. **AWS Account** with appropriate permissions
2. **Base Infrastructure** deployed (`TAK-<n>-BaseInfra`)
3. **Authentication Infrastructure** deployed (`TAK-<n>-AuthInfra`)
4. **Node.js 18+** and npm installed  
5. **AWS CLI** configured with credentials

### **Development Environment Setup**

For developers who will be running tests or working with TAK Server configuration:

```bash
# Install XML validation tools (required for CoreConfig XML schema validation)
sudo apt install libxml2-utils

# Verify installation
xmllint --version
```

**Note**: The `libxml2-utils` package provides `xmllint`, which is required for CoreConfig XML schema validation during testing.

### **Initial Setup Steps**
```bash
# 1. Clone and install
git clone <repository-url>
cd tak-infra
npm install

# 2. Set environment variables (if using AWS profiles)
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text --profile your-profile)
export CDK_DEFAULT_REGION=$(aws configure get region --profile your-profile)

# 3. Deploy TAK Server infrastructure
npm run deploy:dev -- --context stackName=YourStackName
```

---

## **🔄 Environment Transformation**

### **Switching Between Environment Types**

One of the powerful features of this CDK stack is the ability to transform deployed environments between different configuration profiles (dev-test ↔ prod) without recreating resources from scratch.

### **Initial Deployment with Custom Configuration**
You can deploy a stack with custom naming and domain configuration that doesn't follow the standard dev-test or prod patterns:

```bash
# Deploy a demo environment with dev-test configuration
npm run deploy:dev -- --context stackName=Demo --context r53ZoneName=demo.tak.nz
```

This creates a stack named `TAK-Demo-TakInfra` with:
- **Aurora Serverless v2** (cost-optimized)
- **Single AZ deployment** (basic availability)
- **Development-grade settings** for logging and monitoring
- **Minimal ECS resources**

### **Environment Upgrade (dev-test → prod)**
Later, you can upgrade the same stack to production-grade configuration:

```bash
# Transform to production configuration
npm run deploy:prod -- --context stackName=Demo --context r53ZoneName=demo.tak.nz
```

This **upgrades the existing** `TAK-Demo-TakInfra` stack to:
- **Aurora with dedicated instances** (high performance)
- **Multi-AZ deployment** (high availability)
- **Production-grade monitoring** and logging
- **Enhanced ECS resources** with auto-scaling
- **Resource retention policies** (data protection)

### **Environment Downgrade (prod → dev-test)**
You can also downgrade for cost optimization during development phases:

```bash
# Scale back to development configuration
npm run deploy:dev -- --context stackName=Demo --context r53ZoneName=demo.tak.nz
```

### **⚠️ Important Considerations**

1. **Database Changes**: When switching between Aurora Serverless v2 and dedicated instances, there may be brief connection interruptions during the transition.

2. **Removal Policies**: When downgrading from prod to dev-test, resources with `RETAIN` policies will switch to `DESTROY` policies, but existing resources retain their original policy until replaced.

3. **Cost Impact**: Upgrading to prod configuration will significantly increase costs due to dedicated database instances, multi-AZ deployment, and enhanced monitoring.

4. **Incremental Updates**: CDK intelligently updates only the resources that need to change, minimizing disruption to running applications.

### **Best Practices**
- **Test transformations** in a non-critical environment first
- **Plan for brief downtime** during database configuration changes
- **Monitor costs** when upgrading to production configurations
- **Use consistent domain names** across transformations to avoid certificate recreation
- **Backup data** before major configuration changes

---

## **🛠️ Troubleshooting**

### **Common Issues**

#### **Missing Base Infrastructure**
```
Error: Cannot import value TAK-Demo-BaseInfra-VPC-ID
```
**Solution:** Ensure base infrastructure stack is deployed first.

#### **Missing Authentication Infrastructure**
```
Error: Cannot import value TAK-Demo-AuthInfra-LDAP-Service-User-Secret
```
**Solution:** Ensure authentication infrastructure stack is deployed first.

#### **Docker Build Issues**
```
Error: Docker build failed
```
**Solution:** Ensure Docker is running and Dockerfiles exist in docker/ directory.

### **Debug Commands**
```bash
# Check what would be deployed
npm run synth:dev
npm run synth:prod

# See differences from current state
npm run cdk:diff:dev
npm run cdk:diff:prod

# View CloudFormation events
aws cloudformation describe-stack-events --stack-name TAK-Dev-TakInfra
```

---

## **📊 Post-Deployment**

### **Verify Deployment**
```bash
# Check stack status
aws cloudformation describe-stacks --stack-name TAK-Dev-TakInfra

# View outputs
aws cloudformation describe-stacks --stack-name TAK-Dev-TakInfra \
  --query 'Stacks[0].Outputs'
```

### **Access Services**
- **TAK Server Web Interface**: `https://tak.{domain}`
- **TAK Service URL**: `https://ops.{domain}`
- **Certificate Enrollment**: `https://ops.{domain}:8446/Marti/api/tls`

### **Access TAK Admin Certificate**
```bash
# Development environment
aws secretsmanager get-secret-value --secret-id "TAK-Dev-TakInfra/TAK-Server/Admin-Cert" --query SecretString --output text > admin-cert.p12

# Production environment
aws secretsmanager get-secret-value --secret-id "TAK-Prod-TakInfra/TAK-Server/Admin-Cert" --query SecretString --output text > admin-cert.p12

# Custom stack name
aws secretsmanager get-secret-value --secret-id "TAK-{StackName}-TakInfra/TAK-Server/Admin-Cert" --query SecretString --output text > admin-cert.p12
```

### **Cleanup**
```bash
# Destroy development environment
npm run cdk:destroy -- --context env=dev-test

# Destroy production environment (use with caution!)
npm run cdk:destroy -- --context env=prod
```

---

## **🔗 Related Documentation**

- **[Main README](../README.md)** - Project overview and quick start
- **[Architecture Guide](ARCHITECTURE.md)** - Technical architecture details
- **[Configuration Guide](PARAMETERS.md)** - Complete configuration reference
- **[TAK Server CoreConfig](TAKSERVER_CORECONFIG.md)** - Dynamic environment variable configuration
- **[Quick Reference](QUICK_REFERENCE.md)** - Fast deployment commands