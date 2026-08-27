# AWS GitHub Actions Setup for TakInfra

This guide covers setting up GitHub Actions for the TakInfra repository, building on the base infrastructure already configured in BaseInfra.

## Prerequisites

**⚠️ Important:** Steps 1-2 from the [BaseInfra AWS GitHub Setup](https://github.com/TAK-NZ/base-infra/blob/main/docs/AWS_GITHUB_SETUP.md) must be completed first:
- Route 53 DNS setup
- GitHub OIDC Identity Provider and IAM roles

> **Note:** The organization variables and secrets configured in BaseInfra will be used for both environments.

## 3. GitHub Environment Setup for TakInfra

### 3.1 Create Environments

In your TakInfra GitHub repository, go to **Settings → Environments** and create:

1. **`production`** environment
   - **Protection rules:**
     - Required reviewers: Add team leads
     - Wait timer: 5 minutes
     - Deployment branches and tags: Select "Selected branches and tags"
       - Add rule: "v*" (for version tags like v1.0.0)

2. **`demo`** environment
   - **Protection rules:**
     - Deployment branches and tags: Select "Selected branches and tags"
       - Add rule: "main"
   - **Environment variables:**
     - `DEMO_TEST_DURATION`: `300` (wait time in seconds, default 5 minutes)

## 4. Branch Protection Setup

**Configure branch protection for `main`** to ensure only tested code is deployed:

1. Go to **Settings → Branches → Add rule**
2. **Branch name pattern**: `main`
3. **Enable these protections:**
   - ☑️ Require a pull request before merging
   - ☑️ Require status checks to pass before merging
     - ☑️ Require branches to be up to date before merging
     - ☑️ Status checks: Select "Test CDK code" after first workflow run

## 5. Breaking Change Detection for TakInfra

### 5.1 TakInfra-Specific Breaking Changes

**Critical resources that trigger breaking change detection:**
- PostgreSQL database cluster replacements
- EFS file system replacements
- Network Load Balancer replacements
- Secrets Manager secret deletions
- TAK server configuration changes

### 5.2 Implementation

TakInfra uses the same breaking change detection system as BaseInfra:

1. **Stage 1 (PR Level)**: CDK diff analysis during pull requests - fast feedback
2. **Stage 2 (Deploy Level)**: CloudFormation change set validation before demo deployment - comprehensive validation

### 5.3 Override Mechanism

See [BaseInfra's override mechanism](https://github.com/TAK-NZ/base-infra/blob/main/docs/AWS_GITHUB_SETUP.md#54-override-mechanism)
(`[force-deploy]` in the commit message) - identical here.

## 6. GitHub Actions Workflows

### 6.1 Workflow Architecture

### 6.2 Demo Testing Workflow (`demo-deploy.yml`)

**Triggers:**
- Push to `main` branch
- Manual dispatch

**Jobs:**
1. **test**: Run CDK unit tests and linting
2. **build-images**: Build TAK server Docker images for demo environment
3. **validate-prod**: Validate production configuration (runs in parallel)
4. **deploy-and-test**: Deploy with prod profile and run tests
5. **revert-to-dev-test**: Always revert to dev-test configuration

### 6.3 Production Deployment Workflow (`production-deploy.yml`)

**Triggers:**
- Version tags (`v*`)
- Manual dispatch

**Jobs:**
1. **test**: Run CDK unit tests
2. **build-images**: Build TAK server Docker images for production
3. **deploy-production**: Deploy to production with built images (requires approval)

### 6.4 Build Workflows

**Demo Build (`demo-build.yml`):**
- Triggers on push to main (docker/ or cdk.json changes)
- Uses `dev-test` context from cdk.json
- Builds TAK server image with tak-nz branding
- Pushes to demo ECR repository

**Production Build (`production-build.yml`):**
- Triggers only on version tags (`v*`)
- Uses `prod` context from cdk.json
- Builds TAK server image with production configuration
- Pushes to production ECR repository

### 6.5 Required Organization Secrets and Variables

The core organization secrets (`DEMO_AWS_ACCOUNT_ID`, `DEMO_AWS_ROLE_ARN`, `DEMO_AWS_REGION`,
`PROD_AWS_ACCOUNT_ID`, `PROD_AWS_ROLE_ARN`, `PROD_AWS_REGION`) and variables (`DEMO_STACK_NAME`,
`DEMO_TEST_DURATION`, `DEMO_R53_ZONE_NAME`) are configured once at the organization level in
[BaseInfra's setup guide](https://github.com/TAK-NZ/base-infra/blob/main/docs/AWS_GITHUB_SETUP.md#3-github-organization-setup-one-time-configuration)
and used by every layer, including this one.

## 7. Composite Actions

Location: `.github/actions/setup-cdk/action.yml`. Same purpose and benefits as
[BaseInfra's composite action](https://github.com/TAK-NZ/base-infra/blob/main/docs/AWS_GITHUB_SETUP.md#8-composite-actions) -
consolidates checkout, Node.js setup, AWS credentials, and dependency installation into one step.

## 8. Verification

Test the TakInfra setup:

1. **Demo Testing:** Push to `main` branch - Should deploy demo with prod profile, wait, run tests, and revert to dev-test profile
2. **Production:** Create and push version tag (v1.0.0) - Should require approval before deployment

### 8.1 Deployment Flow

**Main Branch Push:**
```
Push to main → Tests → Demo (prod profile) → Wait → Tests → Demo (dev-test profile)
```

**Version Tag Push:**
```
Tag v* → Tests → Production (prod profile) [requires approval]
```

**Benefits:**
- Cost optimization: Demo runs dev-test profile between deployments
- Risk mitigation: Both profiles tested in demo before production
- Separation: Independent workflows for demo testing vs production deployment

## 9. Troubleshooting

### 9.1 Common Workflow Issues

Generic workflow issues (missing secrets/variables, breaking-change validation, image build
failures, CDK synthesis errors, deployment timeouts, composite action errors) and their solutions
are covered in
[BaseInfra's troubleshooting table](https://github.com/TAK-NZ/base-infra/blob/main/docs/AWS_GITHUB_SETUP.md#10-troubleshooting) -
identical here. TakInfra adds one more:

| Issue | Symptoms | Solution |
|-------|----------|----------|
| **TAK Server Download** | S3 download errors | Verify BaseInfra S3 bucket exists and contains TAK server zip |

### 9.2 TAK Server Specific Issues

**Common TAK Server Problems:**

- **Version Mismatch:** Ensure TAK server version in cdk.json matches available zip file
- **Branding Issues:** Verify branding files exist in docker-container/branding/
- **Configuration Errors:** Check TAK server configuration in docker-container/scripts/
- **Certificate Issues:** Verify Let's Encrypt configuration for production

**Troubleshooting Steps:**

1. Check TAK server version in cdk.json
2. Verify stack status in CloudFormation console
3. Review stack events for specific error messages
4. Confirm ECR images are built and tagged correctly
5. Test database connectivity through AWS console
6. Check ECS service logs for container startup issues

### 9.3 Breaking Change Detection

TakInfra-specific breaking changes are listed in §5.1 above. The override process
(`[force-deploy]`) is the same as [BaseInfra's](https://github.com/TAK-NZ/base-infra/blob/main/docs/AWS_GITHUB_SETUP.md#54-override-mechanism):
review the change and plan for downtime, add the override flag, monitor the deployment, then
verify functionality.

### 9.4 Dependencies on BaseInfra and AuthInfra

**Required BaseInfra Resources:**
- VPC and networking (subnets, security groups)
- ECS cluster and service discovery
- KMS keys for encryption
- Route 53 hosted zones
- S3 buckets for CDK assets and TAK server images
- ECR repositories

**Required AuthInfra Resources:**
- PostgreSQL database cluster
- Redis cluster (for session management)
- Application Load Balancer (for OIDC integration)
- Secrets Manager secrets (for database credentials)

Ensure both BaseInfra and AuthInfra are deployed and stable before deploying TakInfra changes.