# Architecture Documentation

## System Architecture

The TAK Server Infrastructure provides centralized TAK communication services with PostgreSQL database backend, EFS storage for certificates, and LDAP authentication integration via the AuthInfra layer.

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   TAK Clients   │────│  Network         │────│   TAK Server    │
│ (ATAK/CloudTAK) │    │  Load Balancer   │    │  (ECS Service)  │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                                        │
                                ┌───────────────────────┼─────────────────┐
                                │                       │                 │
                                ▼                       ▼                 ▼
┌─────────────────┐    ┌──────────────────┐       ┌──────────┐    ┌──────────────┐
│   Auth Layer    │────│   LDAP           │       │   RDS    │    │     EFS      │
│   (AuthInfra)   │    │   Integration    │       │ Aurora   │    │  Certificate │
└─────────────────┘    └──────────────────┘       │PostgreSQL│    │   Storage    │
                                                  └──────────┘    └──────────────┘
```

## Component Details

### Core Services

#### 1. TAK Server Application
- **Technology**: Java-based TAK Server running in ECS Fargate
- **Purpose**: Central TAK communication hub for situational awareness
- **Scaling**: Fixed desired count (1 for dev-test, 1 for production)
- **Storage**: Persistent data in Aurora PostgreSQL, certificates in EFS

#### 2. Database Layer
- **Technology**: Aurora PostgreSQL cluster
- **Purpose**: TAK Server data persistence and user management
- **Configuration**: Serverless v2 (dev) or dedicated instances (prod)
- **Backup**: Automated backups with configurable retention

#### 3. Certificate Management
- **Technology**: EFS file system with access points
- **Purpose**: TAK certificates and Let's Encrypt certificate storage
- **Mount Points**: `/opt/tak/certs/files` and `/etc/letsencrypt` in containers
- **Encryption**: Encrypted at rest and in transit

### Data Layer

#### 1. Aurora PostgreSQL Database
- **Purpose**: Primary data store for TAK Server configuration and operational data
- **Configuration**: Multi-AZ cluster for high availability (production)
- **Backup**: Automated backups with point-in-time recovery
- **Encryption**: Encrypted at rest using AWS KMS

#### 2. EFS File System
- **Purpose**: Shared storage for TAK certificates and Let's Encrypt data
- **Mount Points**: `/opt/tak/certs/files` and `/etc/letsencrypt` in TAK Server containers
- **Backup**: AWS Backup service integration
- **Encryption**: Encrypted at rest and in transit

#### 3. S3 Configuration Storage
- **Purpose**: Optional TAK Server configuration file storage
- **Configuration**: Imported from base infrastructure layer
- **Usage**: Environment file loading for advanced TAK Server configuration

### Network Architecture

#### 1. VPC Configuration
- **Subnets**: Public subnets for NLB, private subnets for services
- **Availability Zones**: Multi-AZ deployment for high availability
- **NAT Gateway**: Outbound internet access for private subnets

#### 2. Load Balancing
- **Network Load Balancer**: Layer 4 load balancing for TAK protocols
- **Target Groups**: Separate target groups for HTTP, CoT TCP, API Admin, WebTAK Admin, and Federation
- **Health Checks**: Custom health check endpoints for TAK Server

#### 3. Security Groups
- **Principle of Least Privilege**: Minimal required access between components
- **Ingress Rules**: Specific port and protocol restrictions for TAK services
- **Egress Rules**: Controlled outbound access

## Environment Configuration System

### 1. Environment Types

#### **dev-test** (Default)
- **Focus**: Cost optimization and development efficiency
- **Database**: Aurora Serverless v2 (single instance, auto-scaling)
- **ECS**: Minimal CPU/memory allocation (2048/4096)
- **Container Insights**: Disabled
- **ECS Exec**: Enabled (debugging access)
- **S3 Config File**: Disabled (uses environment variables)
- **ECR**: 5 image retention, no vulnerability scanning
- **Resource Removal**: DESTROY policy (allows cleanup)

#### **prod**
- **Focus**: High availability, security, and production readiness
- **Database**: Aurora PostgreSQL (2 instances, multi-AZ)
- **ECS**: Higher resource allocation (4096/8192)
- **Container Insights**: Enabled (monitoring and observability)
- **ECS Exec**: Disabled (security)
- **S3 Config File**: Enabled (advanced configuration)
- **ECR**: 20 image retention, vulnerability scanning enabled
- **Resource Removal**: RETAIN policy (protects production resources)

### 2. Parameter Override System
- **Environment Variables**: Highest precedence override mechanism
- **CDK Context**: CLI-based parameter overrides
- **Environment Defaults**: Fallback configuration based on environment type
- **Hierarchical Resolution**: Context → Environment Variables → Environment Defaults

## Security Architecture

### 1. Network Security Groups

The infrastructure implements a layered security model with dedicated security groups for each component, following the principle of least privilege.

#### Application Services

**TAK Server Security Group**
- **Port 80/TCP** from NLB Security Group only - HTTP traffic from NLB
- **Port 8089/TCP** from NLB Security Group only - CoT TCP traffic from NLB
- **Port 8443/TCP** from NLB Security Group only - API Admin traffic from NLB
- **Port 8446/TCP** from NLB Security Group only - WebTAK Admin traffic from NLB
- **Port 9001/TCP** from NLB Security Group only - Federation traffic from NLB

**Network Load Balancer Security Group**
- **Port 80/TCP** from `0.0.0.0/0` (IPv4) and `::/0` (IPv6) - HTTP access
- **Port 8089/TCP** from `0.0.0.0/0` (IPv4) and `::/0` (IPv6) - CoT TCP access
- **Port 8443/TCP** from `0.0.0.0/0` (IPv4) and `::/0` (IPv6) - API Admin access
- **Port 8446/TCP** from `0.0.0.0/0` (IPv4) and `::/0` (IPv6) - WebTAK Admin access
- **Port 9001/TCP** from `0.0.0.0/0` (IPv4) and `::/0` (IPv6) - Federation access

#### Data Layer Services

**Database Security Group**
- **Port 5432/TCP** from TAK Server Security Group - PostgreSQL access from TAK Server

**EFS Security Group**
- **Port 2049/TCP** from TAK Server Security Group - NFS access from TAK Server

#### Security Design Principles

- **Network Segmentation**: Each service tier has dedicated security groups
- **Minimal Access**: Only required ports and protocols are allowed
- **Database Access**: Only TAK Server can access the database
- **EFS Access**: Only TAK Server can mount EFS volumes
- **Dualstack Support**: Internet-facing services support both IPv4 and IPv6
- **No Broad Access**: Database and EFS only accept traffic from TAK Server security group

### 2. Encryption
- **In Transit**: TLS 1.2+ for all communications
- **At Rest**: AWS KMS encryption for all data stores
- **Key Management**: Imported KMS keys from base infrastructure

### 3. Access Control
- **IAM Roles**: Service-specific roles with minimal permissions
- **Security Groups**: Network-level access control (detailed above)
- **Secrets Management**: AWS Secrets Manager for sensitive data

### 4. Monitoring and Logging
- **CloudWatch Logs**: Application and system logs
- **CloudWatch Metrics**: Performance and health metrics
- **AWS CloudTrail**: API access logging

## TAK Server Integration

### 1. LDAP Authentication
- **Integration**: Connects to AuthInfra LDAP service
- **Protocol**: LDAPS (LDAP over TLS)
- **Service Account**: Dedicated LDAP service account from AuthInfra
- **User Management**: Centralized user management via Authentik

### 2. Certificate Management
- **Admin Certificates**: Stored in AWS Secrets Manager
- **Let's Encrypt**: Automated certificate generation and renewal
- **TAK Certificates**: Persistent storage in EFS
- **Certificate Enrollment**: Automated certificate enrollment endpoints

### 3. Configuration Management
- **Environment Variables**: Core configuration via ECS environment variables
- **S3 Configuration**: Optional advanced configuration via S3 files
- **Database Configuration**: PostgreSQL connection and credentials
- **LDAP Configuration**: Integration with AuthInfra LDAP service

## Deployment Architecture

### 1. Infrastructure as Code
- **AWS CDK**: TypeScript-based infrastructure definitions
- **Version Control**: Git-based infrastructure versioning
- **Automated Testing**: Unit tests for infrastructure code

### 2. Container Management
- **ECR**: Private container registry
- **ECS Fargate**: Serverless container platform
- **Docker Images**: Automated building and deployment

### 3. Dependency Management
- **Base Infrastructure**: VPC, ECS cluster, S3, KMS, ACM certificates
- **Authentication Infrastructure**: LDAP service and user management
- **CloudFormation Exports**: Cross-stack resource sharing

## Resource Allocation and Performance

### 1. Resource Allocation
- **ECS Service**: Fixed desired count based on environment configuration
- **Database**: Aurora auto-scaling for serverless configurations (dev-test only)
- **Task Count**: 1 task for both environments

### 2. High Availability
- **Multi-AZ**: Database and ECS service deployment across availability zones
- **Load Balancing**: Network Load Balancer for traffic distribution
- **Health Checks**: Automated health monitoring and recovery

### 3. Performance Optimization
- **Database**: Performance Insights enabled in production
- **Container Resources**: Environment-specific CPU and memory allocation
- **Monitoring**: Container Insights for detailed performance metrics

## Cost Optimization

### Development Environment Optimizations
- **Aurora Serverless v2**: Pay-per-use database scaling
- **Single AZ**: Reduced availability zone costs
- **Smaller ECS Tasks**: Minimal CPU/memory allocation
- **Container Insights Disabled**: Reduces CloudWatch costs

### Production Environment Features
- **High Availability**: Multi-AZ database and ECS deployment
- **Enhanced Monitoring**: Performance Insights, Container Insights
- **Advanced Configuration**: S3-based configuration management
- **Image Management**: Extended ECR retention, vulnerability scanning