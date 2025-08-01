# TAK Server Infrastructure

<p align=center>Modern AWS CDK v2 infrastructure for Team Awareness Kit (TAK) Server deployments

## Overview

The [Team Awareness Kit (TAK)](https://tak.gov/solutions/emergency) provides Fire, Emergency Management, and First Responders an operationally agnostic tool for improved situational awareness and a common operational picture. 

This repository deploys the TAK Server infrastructure layer for a complete TAK deployment, providing robust PostgreSQL database, EFS storage, and containerized TAK Server deployment with advanced capabilities such as LDAP authentication integration, certificate management, and enterprise-grade security features.

It is specifically targeted at the deployment of [TAK.NZ](https://tak.nz) via a CI/CD pipeline. Nevertheless others interested in deploying a similar infrastructure can do so by adapting the configuration items.

### Architecture Layers

This TAK Server infrastructure requires the base infrastructure and authentication infrastructure layers. Layers can be deployed in multiple independent environments. As an example:

```
        PRODUCTION ENVIRONMENT                DEVELOPMENT ENVIRONMENT
        Domain: tak.nz                        Domain: dev.tak.nz

┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│         CloudTAK                │    │         CloudTAK                │
│    CloudFormation Stack         │    │    CloudFormation Stack         │
└─────────────────────────────────┘    └─────────────────────────────────┘
                │                                        │
                ▼                                        ▼
┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│         TakInfra                │    │         TakInfra                │
│    CloudFormation Stack         │    │    CloudFormation Stack         │
│      (This Repository)          │    │      (This Repository)          │
└─────────────────────────────────┘    └─────────────────────────────────┘
                │                                        │
                ▼                                        ▼
┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│        AuthInfra                │    │        AuthInfra                │
│    CloudFormation Stack         │    │    CloudFormation Stack         │
└─────────────────────────────────┘    └─────────────────────────────────┘
                │                                        │
                ▼                                        ▼
┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│        BaseInfra                │    │        BaseInfra                │
│    CloudFormation Stack         │    │    CloudFormation Stack         │
└─────────────────────────────────┘    └─────────────────────────────────┘
```

| Layer | Repository | Description |
|-------|------------|-------------|
| **BaseInfra** | [`base-infra`](https://github.com/TAK-NZ/base-infra)  | Foundation: VPC, ECS, S3, KMS, ACM |
| **AuthInfra** | [`auth-infra`](https://github.com/TAK-NZ/auth-infra) | SSO via Authentik, LDAP |
| **TakInfra** | `tak-infra` (this repo) | TAK Server |
| **CloudTAK** | [`CloudTAK`](https://github.com/TAK-NZ/CloudTAK) | CloudTAK web interface, ETL, and media services |

**Deployment Order**: BaseInfra must be deployed first, followed by AuthInfra, then TakInfra, and finally CloudTAK. Each layer imports outputs from the layer below via CloudFormation exports.

## Quick Start

### Prerequisites
- [AWS Account](https://signin.aws.amazon.com/signup) with configured credentials
- Base infrastructure stack (`TAK-<n>-BaseInfra`) must be deployed first
- Authentication infrastructure stack (`TAK-<n>-AuthInfra`) must be deployed first
- Public Route 53 hosted zone (e.g., `tak.nz`)
- [Node.js](https://nodejs.org/) and npm installed
- Development tools: `libxml2-utils` for XML validation (see [Deployment Guide](docs/DEPLOYMENT_GUIDE.md#development-environment-setup))
- **TAK Server Distribution**: Download `takserver-docker-<version>.zip` from https://tak.gov/products/tak-server and either:
  - Place it in the root directory of this repository, OR
  - Upload it to the S3 TAK Images bucket (exported as `TAK-<n>-BaseInfra-S3TAKImagesArn`)

### Installation & Deployment

```bash
# 1. Download TAK Server distribution
# Download takserver-docker-<version>.zip from https://tak.gov/products/tak-server
# Either:
#   - Place the file in the root directory of this repository, OR
#   - Upload to S3 bucket (see TAK Server Distribution section below)

# 2. Install dependencies
npm install

# 3. Bootstrap CDK (first time only)
npx cdk bootstrap --profile your-aws-profile

# 4. Deploy development environment
npm run deploy:dev

# 5. Deploy production environment  
npm run deploy:prod
```

## Infrastructure Resources

### Database & Storage
- **RDS Aurora PostgreSQL** - Encrypted cluster with backup retention for TAK Server data
- **EFS File System** - Persistent TAK certificates and Let's Encrypt storage
- **S3 Bucket** - Configuration storage with KMS encryption (imported from base layer)

### Compute & Services
- **ECS Service** - TAK Server container with fixed desired count (1 for dev-test, 2 for production)
- **Network Load Balancer** - Layer 4 load balancing for TAK protocols
- **Target Groups** - HTTP, CoT TCP, API Admin, WebTAK Admin, and Federation endpoints

### Security & DNS
- **AWS Secrets Manager** - Database credentials and TAK admin certificates
- **Security Groups** - Fine-grained network access controls
- **Route 53 Records** - TAK Server endpoint DNS management
- **KMS Encryption** - Data encryption at rest and in transit

## Docker Image Handling

This stack uses a **hybrid Docker image strategy** that supports both pre-built images from ECR and local Docker building for maximum flexibility.

- **Strategy**: See [Docker Image Strategy Guide](docs/DOCKER_IMAGE_STRATEGY.md) for details
- **CI/CD Mode**: Uses pre-built images for fast deployments (~8 minutes vs ~20 minutes)
- **Development Mode**: Builds images locally for flexible development
- **Automatic Fallback**: Seamlessly switches between modes based on context parameters

### Docker Images Used

1. **TAK Server**: Built from `docker/tak-server/Dockerfile.{branding}` with version and revision tagging

### TAK Server Distribution

The TAK Server Docker images require the official TAK Server distribution file. You have two options:

#### Option 1: Local Repository (Default)
Place `takserver-docker-<version>.zip` in the root directory of this repository.

#### Option 2: S3 Bucket (Recommended for CI/CD)
Upload the [TAK Server distribution](https://tak.gov/products/tak-server) to the S3 bucket created by BaseInfra:

```bash
# Get the S3 bucket name from CloudFormation export
BUCKET_ARN=$(aws cloudformation describe-stacks --stack-name TAK-<n>-BaseInfra \
  --query 'Stacks[0].Outputs[?OutputKey==`S3TAKImagesArnOutput`].OutputValue' --output text)
BUCKET_NAME=$(echo $BUCKET_ARN | sed 's|arn:aws:s3:::|s3://|')

# Upload TAK Server distribution
aws s3 cp takserver-docker-5.4-RELEASE-19.zip $BUCKET_NAME/
```

**Note**: The Docker build process will automatically check the local repository first, then fall back to downloading from S3 if the file is not found locally.

### Branding Support

The stack supports different Docker image variants via the `branding` configuration:
- **`tak-nz`**: TAK.NZ branded images (default)
- **`generic`**: Generic TAK branded images

### TAK Server Version

Docker images are built with the TAK Server version specified in configuration:
```json
"takserver": {
  "version": "5.4-RELEASE-19"
}
```

## Available Environments

| Environment | Stack Name | Description | Domain | Monthly Cost* |
|-------------|------------|-------------|--------|----------------|
| `dev-test` | `TAK-Dev-TakInfra` | Cost-optimized development | `tak.dev.tak.nz` | ~$65 USD |
| `prod` | `TAK-Prod-TakInfra` | High-availability production | `tak.tak.nz` | ~$285 USD |

*Estimated AWS costs (USD) for ap-southeast-2, excluding data transfer and storage usage

## Development Workflow

### New NPM Scripts (Enhanced Developer Experience)
```bash
# Development and Testing
npm run dev                    # Build and test
npm run test:watch            # Run tests in watch mode
npm run test:coverage         # Generate coverage report

# Environment-Specific Deployment
npm run deploy:dev            # Deploy to dev-test
npm run deploy:prod           # Deploy to production
npm run synth:dev             # Preview dev infrastructure
npm run synth:prod            # Preview prod infrastructure

# Infrastructure Management
npm run cdk:diff:dev          # Show what would change in dev
npm run cdk:diff:prod         # Show what would change in prod
npm run cdk:bootstrap         # Bootstrap CDK in account
```

### Configuration System

The project uses **AWS CDK context-based configuration** for consistent deployments:

- **All settings** stored in [`cdk.json`](cdk.json) under `context` section
- **Version controlled** - consistent deployments across team members
- **Runtime overrides** - use `--context` flag for one-off changes
- **Environment-specific** - separate configs for dev-test and production

#### Configuration Override Examples
```bash
# Override TAK Server hostname for deployment
npm run deploy:dev -- --context hostname=ops

# Deploy with different TAK Server version
npm run deploy:prod -- --context version=5.5-RELEASE-1

# Use different branding
npm run deploy:dev -- --context branding=generic
```

## 📚 Documentation

- **[🚀 Deployment Guide](docs/DEPLOYMENT_GUIDE.md)** - Comprehensive deployment instructions and configuration options
- **[🏗️ Architecture Guide](docs/ARCHITECTURE.md)** - Technical architecture and design decisions  
- **[⚡ Quick Reference](docs/QUICK_REFERENCE.md)** - Fast deployment commands and environment comparison
- **[⚙️ Configuration Guide](docs/PARAMETERS.md)** - Complete configuration management reference
- **[🔧 TAK Server CoreConfig](docs/TAKSERVER_CORECONFIG.md)** - Dynamic environment variable configuration system
- **[🔐 WebTAK OIDC Integration](docs/WEBTAK_OIDC.md)** - Single sign-on authentication setup with Authentik
- **[🐳 Docker Image Strategy](docs/DOCKER_IMAGE_STRATEGY.md)** - Hybrid image strategy for fast CI/CD and flexible development

## Security Features

### Enterprise-Grade Security
- **🔑 KMS Encryption** - All data encrypted with customer-managed keys
- **🛡️ Network Security** - Private subnets with controlled internet access
- **🔒 IAM Policies** - Least-privilege access patterns throughout
- **📋 LDAP Integration** - Secure LDAP authentication with Authentik
- **🔐 Certificate Management** - Automated Let's Encrypt certificate handling

## Getting Help

### Common Issues
- **Base Infrastructure** - Ensure base infrastructure stack is deployed first
- **Authentication Infrastructure** - Ensure authentication infrastructure stack is deployed first
- **Route53 Hosted Zone** - Ensure your domain's hosted zone exists before deployment
- **AWS Permissions** - CDK requires broad permissions for CloudFormation operations
- **Docker Images** - CDK automatically handles Docker image building and ECR management
- **Stack Name Matching** - Ensure stackName parameter matches your base and auth infrastructure deployments

### Support Resources
- **AWS CDK Documentation** - https://docs.aws.amazon.com/cdk/
- **TAK Server Documentation** - https://tak.gov/
- **TAK-NZ Project** - https://github.com/TAK-NZ/
- **Issue Tracking** - Use GitHub Issues for bug reports and feature requests