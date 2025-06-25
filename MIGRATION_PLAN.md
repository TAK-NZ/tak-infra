# TAK Infrastructure Migration Plan: OpenAddress/Deploy to AWS CDK

## Overview

This document outlines the comprehensive migration plan to convert the TAK Infrastructure project from using `@openaddresses/deploy` with CloudFormation templates to AWS CDK, following the patterns established in the reference projects `base-infra` and `auth-infra`.

**📋 Progress Tracking**: Check off the boxes in each phase as tasks are completed during the 12-17 day implementation period.

## Current State Analysis

### Current Architecture
- **Deployment Tool**: `@openaddresses/deploy` with CloudFormation templates
- **Stack Structure**: Two separate stacks:
  1. `base.template.js` - Infrastructure (DB, EFS, ELB)
  2. `tak-infra.template.js` - Application (TAK Server ECS service)
- **Resources**: PostgreSQL Aurora, EFS, Network Load Balancer, ECS Fargate service
- **Docker Images**: Two variants (generic and tak-nz branded)
- **Configuration**: Environment variables and S3-based config files

### Reference Projects Structure
- **base-infra**: VPC, ECS Cluster, KMS, S3, ACM certificates, Route53
- **auth-infra**: Authentik authentication service with PostgreSQL, Redis, EFS
- **Deployment Order**: base-infra → auth-infra → tak-infra (this project)

## Migration Strategy

### Phase 1: Project Structure Setup
**Duration**: 1-2 days

#### 1.1 Initialize CDK Project Structure
- [x] Create new CDK project structure following reference patterns
- [x] Set up TypeScript configuration
- [x] Configure package.json with CDK dependencies
- [x] Create bin/, lib/, test/ directories
- [x] Set up Jest testing framework
- [x] Configure ESLint and TypeScript compiler

#### 1.2 Configuration Management
- [x] Create `cdk.json` with environment contexts (dev-test, prod)
- [x] Implement context-based configuration system
- [x] Create stack configuration interfaces
- [x] Set up environment-specific parameters
- [x] Configure CDK feature flags

#### 1.3 Utility Infrastructure
- [x] Create utility functions for tagging
- [x] Implement CloudFormation import helpers
- [x] Set up constants and configuration validators
- [x] Create context override mechanisms

### Phase 2: Core Infrastructure Migration ✅ **COMPLETED**
**Duration**: 3-4 days

#### 2.1 Stack Architecture Design ✅
- [x] Design single unified CDK stack (merge current base + tak-infra stacks)
- [x] Implement automated deployment with proper resource dependencies:
  1. **Infrastructure Resources**: Database, EFS, Load Balancer, Security Groups
  2. **DNS Resources**: Route53 records (automated, following auth-infra pattern)
  3. **Application Resources**: ECS service (with dependencies on infrastructure)
- [x] Eliminate manual DNS management steps through CDK dependencies

#### 2.2 Database Construct ✅
- [x] Migrate PostgreSQL Aurora cluster configuration
- [x] Implement Secrets Manager integration
- [x] Configure security groups and subnet groups
- [x] Set up monitoring and performance insights
- [x] Handle multi-AZ deployment for production

#### 2.3 Storage Constructs ✅
- [x] Migrate EFS file system configuration
- [x] Create access points for TAK certs and Let's Encrypt
- [x] Configure mount targets and security groups
- [x] Implement encryption with imported KMS key

#### 2.4 Load Balancer Construct ✅
- [x] Migrate Network Load Balancer configuration with dualstack IP addressing
- [x] Set up target groups for all TAK ports (80, 443, 8089, 8443, 8446, 9001)
- [x] Configure health checks and load balancer attributes
- [x] Implement IPv4/IPv6 dualstack security group rules (following auth-infra pattern)

### Phase 3: Application Service Migration
**Duration**: 2-3 days

#### 3.1 ECS Service Construct ✅
- [x] Migrate ECS task definition
- [x] Configure container definitions with environment variables
- [x] Set up volume mounts for EFS
- [x] Implement secrets integration
- [x] Configure logging and monitoring

#### 3.2 Docker Image Management ✅
- [x] Use CDK DockerImageAsset for local Docker builds (like auth-infra)
- [x] Support generic and tak-nz branded Dockerfiles
- [x] Implement build-time arguments for TAK Server version
- [x] Remove GitHub Container Registry option - use CDK's built-in ECR capabilities

#### 3.3 Security and IAM ✅
- [x] Migrate task and execution roles
- [x] Configure IAM policies for secrets access
- [x] Set up ECS Exec permissions
- [x] Implement KMS permissions for encryption
- [x] Configure IPv4/IPv6 dualstack security group rules for all services

### Phase 4: DNS and Routing
**Duration**: 1-2 days

#### 4.1 Route53 Integration
- [ ] Import hosted zone from base-infra
- [ ] Create Route53 construct following auth-infra pattern
- [ ] Implement A and AAAA record creation (IPv4/IPv6 dualstack)
- [ ] Configure DNS aliases for dualstack load balancer

#### 4.2 SSL Certificate Integration
- [ ] Import ACM certificate from base-infra
- [ ] Configure HTTPS listeners
- [ ] Set up certificate validation

### Phase 5: Configuration and Environment Management
**Duration**: 2-3 days

#### 5.1 Environment Configuration
- [ ] Create comprehensive context configuration
- [ ] Implement environment-specific settings (dev-test vs prod)
- [ ] Configure resource sizing and scaling parameters
- [ ] Set up feature flags and toggles

#### 5.2 S3 Configuration File Support
- [ ] Implement S3 environment file integration
- [ ] Configure ECS environment file loading
- [ ] Set up IAM permissions for S3 access
- [ ] Support optional configuration file usage

#### 5.3 Secrets Management
- [ ] Migrate database credentials to Secrets Manager
- [ ] Configure LDAP service account secrets
- [ ] Set up OAuth configuration secrets
- [ ] Implement secret rotation policies

### Phase 6: Testing and Validation
**Duration**: 2-3 days

#### 6.1 Unit Testing
- [ ] Create comprehensive unit tests for all constructs
- [ ] Test configuration validation
- [ ] Validate resource creation logic
- [ ] Test error handling and edge cases

#### 6.2 Integration Testing
- [ ] Test stack synthesis and deployment
- [ ] Validate resource dependencies
- [ ] Test cross-stack references
- [ ] Verify security group rules and networking

#### 6.3 End-to-End Testing
- [ ] Deploy to development environment
- [ ] Validate TAK Server functionality
- [ ] Test container deployment and scaling
- [ ] Verify DNS resolution and SSL certificates

### Phase 7: Documentation and Deployment
**Duration**: 1-2 days

#### 7.1 Documentation
- [ ] Create comprehensive README
- [ ] Document deployment procedures
- [ ] Create architecture diagrams
- [ ] Document configuration options
- [ ] Create troubleshooting guide
- [ ] Document TAK admin certificate download procedure:
  ```bash
  # After CDK deployment
  aws secretsmanager get-secret-value --secret-id "TAK-Dev-TakInfra/TAK-Server/Admin-Cert" --query SecretString --output text > admin-cert.p12
  ```
- [ ] Document secret naming changes from CloudFormation:
  - **Old**: `${stackName}/tak-admin-cert`
  - **New**: `${stackName}/TAK-Server/Admin-Cert` (consistent with AuthInfra patterns)
- [ ] Document cross-stack reference updates:
  - **Old CloudFormation**: `coe-auth-${environment}`, `coe-tak-base-${environment}`
  - **New CDK**: `TAK-${envName}-AuthInfra`, `TAK-${envName}-BaseInfra`

#### 7.2 CI/CD Integration
- [ ] Update GitHub Actions workflows
- [ ] Configure CDK deployment pipelines
- [ ] Set up automated testing
- [ ] Remove Docker image publishing workflows (CDK handles this)
- [ ] Implement security scanning

## Detailed Implementation Plan

### Stack Structure

**Single CDK Stack**: `TAK-{Environment}-TakInfra`

All resources deployed in one stack with proper CDK dependencies:
```
TAK-{Environment}-TakInfra (Single Stack)
├── Infrastructure Resources (created first)
│   ├── Database (Aurora PostgreSQL)
│   ├── EFS (File System + Access Points)
│   ├── Load Balancer (NLB + Target Groups)
│   └── Security Groups
├── DNS Resources (depends on Load Balancer)
│   ├── Route53 Records (A/AAAA) - automated
│   └── SSL Certificate Integration
└── Application Resources (depends on Infrastructure + DNS)
    ├── ECS Task Definition
    ├── ECS Service
    └── IAM Roles
```

**Key Improvement**: Eliminates the current manual DNS step between base and tak-infra stacks by automating Route53 record creation within the single stack, similar to how auth-infra handles DNS automatically.

### Key Constructs to Create

1. **TakDatabase** - PostgreSQL Aurora cluster with secrets
2. **TakEfs** - EFS file system with access points
3. **TakLoadBalancer** - NLB with multiple target groups
4. **TakSecurityGroups** - All required security groups
5. **TakEcsService** - ECS service with task definition
6. **TakRoute53** - DNS records and routing
7. **TakSecretsManager** - Application secrets

### Configuration Structure

```typescript
interface TakInfraConfig {
  database: {
    version: string;
    instanceClass: string;
    multiAz: boolean;
    backupRetention: number;
  };
  ecs: {
    cpu: number;
    memory: number;
    desiredCount: number;
    enableExec: boolean;
  };
  takserver: {
    hostname: string;
    branding: 'generic' | 'tak-nz';
    version: string;
    useS3Config: boolean;
  };
  // networking configuration removed - always use dualstack
}
```

### Dependencies and Imports

The stack will import the following from base-infra:
- VPC and subnets
- ECS cluster
- KMS key
- S3 configuration bucket
- Route53 hosted zone
- ACM certificate

The stack will import the following from auth-infra:
- LDAP service credentials
- LDAP base DN
- Authentication endpoints

### Environment-Specific Configurations

#### Development (dev-test)
- Single database instance
- Minimal resource allocation
- Debug logging enabled
- ECS Exec enabled
- Removal policy: DESTROY

#### Production (prod)
- Multi-AZ database deployment
- Higher resource allocation
- Optimized logging
- ECS Exec disabled
- Removal policy: RETAIN
- Enhanced monitoring

## Implementation Checklist

### Pre-Implementation
- [ ] Document current resource configurations for reference
- [ ] Identify all dependencies from base-infra and auth-infra
- [ ] Set up testing environment
- [ ] Plan new naming conventions

### Implementation Execution
- [ ] Complete Phase 1: Project Setup
- [x] Complete Phase 2: Core Infrastructure
- [ ] Complete Phase 3: Application Service
- [ ] Complete Phase 4: DNS and Routing
- [ ] Complete Phase 5: Configuration Management
- [ ] Complete Phase 6: Testing and Validation
- [ ] Complete Phase 7: Documentation and Deployment

### Post-Implementation
- [ ] Validate all functionality in new environment
- [ ] Update deployment documentation
- [ ] Train team on new deployment process
- [ ] Plan eventual decommissioning of old stacks (separate project)

## Risk Mitigation

### Implementation Risks
- **Risk**: Resource naming conflicts with existing stacks
- **Mitigation**: Use new naming convention (TAK-{Environment}-TakInfra) and test in isolated environment

- **Risk**: Missing functionality from current setup
- **Mitigation**: Comprehensive documentation review and feature comparison testing

- **Risk**: Integration issues with base-infra/auth-infra
- **Mitigation**: Thorough testing of all imported resources and dependencies

### Technical Risks
- **Risk**: Configuration drift from reference patterns
- **Mitigation**: Strict adherence to auth-infra patterns and comprehensive testing

- **Risk**: Security group misconfigurations
- **Mitigation**: Copy exact patterns from auth-infra and thorough security review

## Success Criteria

1. **Functional**: TAK Server deploys and operates identically to current setup
2. **Performance**: No degradation in application performance
3. **Security**: All security configurations maintained or improved
4. **Maintainability**: Code is well-documented and follows CDK best practices
5. **Testability**: Comprehensive test coverage for all components
6. **Deployability**: Reliable, repeatable deployment process

## Critical Implementation Notes

### Key Architectural Decisions
1. **Greenfield Deployment**: Building completely new stacks with new naming convention (TAK-{Environment}-TakInfra)
2. **Single Stack Deployment**: Unlike current two-stack approach, CDK will deploy everything in one stack with proper dependencies
3. **Always Dualstack**: Remove IPv4/IPv6 choice - always use dualstack like auth-infra
4. **CDK Docker Assets**: Remove GitHub registry option - use CDK's built-in ECR capabilities
5. **Automated DNS**: Eliminate manual Route53 management between deployments
6. **New Naming Convention**: Follow BaseInfra/AuthInfra patterns instead of current coe-tak naming

### Essential Reference Patterns to Follow
**⚠️ CRITICAL: Always check reference projects before implementing any new code**

- **Security Groups**: Copy auth-infra's dual IPv4/IPv6 rule pattern exactly
- **Docker Management**: Use auth-infra's DockerImageAsset pattern with branding support
- **Route53 Integration**: Follow auth-infra's automated A/AAAA record creation
- **Configuration Structure**: Match auth-infra's context-based configuration approach
- **Import Patterns**: Use same CloudFormation import utilities as auth-infra
- **File Organization**: Follow exact lib/ structure as base-infra and auth-infra (lib/constructs/, lib/utils/, lib/stack-config.ts, lib/cloudformation-imports.ts, lib/utils.ts)
- **Interface Naming**: Use ContextEnvironmentConfig pattern for consistency
- **Utility Functions**: Match function signatures and patterns from reference projects
- **Tag Helpers**: Use generateStandardTags() pattern, not direct tag application
- **Function Names**: Match exact function names from reference projects (e.g., generateStandardTags, not applyStandardTags)
- **Return Types**: Functions should return objects/values, not perform side effects when possible

### Current vs Target State
| Current | Target (CDK) |
|---------|-------------|
| Two separate stacks | Single unified stack |
| Manual DNS between stacks | Automated DNS via CDK dependencies |
| GitHub/ECR image choice | CDK DockerImageAsset only |
| IPv4/dualstack choice | Always dualstack |
| Manual CloudFormation | CDK with TypeScript |

### Critical Dependencies
- **base-infra exports**: VPC, ECS cluster, KMS, S3, Route53, ACM certificate
- **auth-infra exports**: LDAP credentials, base DN, authentication endpoints
- **Docker structure**: Must reorganize current docker/ directory to match auth-infra pattern

### Port Mapping Requirements
TAK Server requires these specific ports (all must be preserved):
- 80 (HTTP redirect)
- 443 (HTTPS/WebTAK)
- 8089 (CoT TCP)
- 8443 (API/Admin)
- 8446 (WebTAK/Admin)
- 9001 (Federation)

### Environment Variable Migration
Critical environment variables that must be preserved:
- Database connection strings
- LDAP configuration
- OAuth/OIDC settings
- TAK Server specific configurations
- Let's Encrypt settings

## Timeline Summary

- **Total Duration**: 12-17 days
- **Phase 1**: 1-2 days (Project Setup)
- **Phase 2**: 3-4 days (Core Infrastructure)
- **Phase 3**: 2-3 days (Application Service)
- **Phase 4**: 1-2 days (DNS and Routing)
- **Phase 5**: 2-3 days (Configuration Management)
- **Phase 6**: 2-3 days (Testing and Validation)
- **Phase 7**: 1-2 days (Documentation and Deployment)

This migration plan provides a structured approach to converting the TAK Infrastructure from OpenAddress/Deploy to AWS CDK while maintaining compatibility with the existing base-infra and auth-infra reference projects.