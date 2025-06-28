# TAK Server Infrastructure - Quick Reference

## Quick Deployment Commands

### Using Enhanced NPM Scripts (Recommended)
```bash
# Development environment (cost-optimized)
npm run deploy:dev

# Production environment (high availability)
npm run deploy:prod
```

### Using Direct CDK Commands
```bash
# Development environment
npx cdk deploy --context env=dev-test --profile your-aws-profile

# Production environment
npx cdk deploy --context env=prod --profile your-aws-profile
```

## Environment Comparison

### Development Environment (`dev-test`)
- ✅ **Cost optimized** (~$91/month)
- ✅ **Same core functionality** as production
- ✅ **Perfect for development** and testing
- ✅ **Aurora Serverless v2** (pay-per-use scaling)
- ❌ **Single AZ deployment** (potential downtime during maintenance)
- ❌ **Basic monitoring** (limited insights)
- ❌ **Single ECS task** (no auto-scaling)

### Production Environment (`prod`)
- ✅ **High availability** (Multi-AZ deployment)
- ✅ **Enhanced monitoring** (Performance Insights, Container Insights)
- ✅ **Production-grade database** (dedicated instances)
- ✅ **Auto-scaling** (ECS service scaling)
- ✅ **Data protection** (retention policies)
- ❌ **Higher cost** (~$390/month)

## Configuration Override Examples

```bash
# Custom domain deployment
npm run deploy:dev -- --context r53ZoneName=custom.tak.nz

# Enhanced development environment
npm run deploy:dev -- --context instanceClass=db.t4g.small

# Custom TAK Server configuration
npm run deploy:prod -- --context hostname=ops --context servicename=tak

# High-performance development
npm run deploy:dev -- \
  --context taskCpu=4096 \
  --context taskMemory=8192 \
  --context desiredCount=2
```

## Infrastructure Resources

| Resource | Dev-Test | Production | Notes |
|----------|----------|------------|-------|
| **Aurora PostgreSQL** | **Serverless v2** | **Dedicated (Multi-AZ)** | Major cost/performance difference |
| **ECS Tasks** | 1 × 2048/4096 | 2 × 4096/8192 | CPU/Memory allocation |
| **Network Load Balancer** | 1 | 1 | TAK protocol traffic |
| **EFS File System** | 1 | 1 | Certificate storage |
| **Secrets Manager** | 2 secrets | 2 secrets | Admin cert, DB credentials |
| **ECR Repositories** | 1 | 1 | TAK Server image |
| **CloudWatch Logs** | Basic | Enhanced | Retention and insights |

## Cost Breakdown (Estimated for ap-southeast-2)

### TAK Server Infrastructure Only

#### Development Environment (~$91/month)
- **Aurora Serverless v2**: ~$25/month (0.5 ACU average)
- **ECS Fargate**: ~$35/month (2048 CPU, 4096 MB, 1 task)
- **Network Load Balancer**: ~$18/month
- **EFS Storage**: ~$3/month
- **Other Services**: ~$10/month (logs, secrets, etc.)

#### Production Environment (~$390/month)
- **Aurora Multi-AZ**: ~$200/month (2 × db.t4g.large)
- **ECS Fargate**: ~$140/month (4096 CPU, 8192 MB, 2 tasks)
- **Network Load Balancer**: ~$18/month
- **Enhanced Features**: ~$20/month (monitoring, insights)
- **Other Services**: ~$12/month (logs, secrets, etc.)

### Complete TAK Deployment (BaseInfra + AuthInfra + TakInfra)

#### Development Environment (~$220/month)
- **BaseInfra**: ~$44/month (VPC, ECS cluster, S3, KMS, ACM)
- **AuthInfra**: ~$85/month (Authentik, LDAP, Aurora, Redis)
- **TakInfra**: ~$91/month (TAK Server, Aurora, EFS)

#### Production Environment (~$778/month)
- **BaseInfra**: ~$143/month (VPC, ECS cluster, S3, KMS, ACM, VPC endpoints)
- **AuthInfra**: ~$245/month (Authentik HA, LDAP, Aurora Multi-AZ, Redis cluster)
- **TakInfra**: ~$390/month (TAK Server HA, Aurora Multi-AZ, enhanced monitoring)

## Development Workflow

### Available NPM Scripts
```bash
# Development and Testing
npm run build                # Build TypeScript
npm run test                 # Run unit tests
npm run test:watch          # Run tests in watch mode
npm run test:coverage       # Generate coverage report

# Infrastructure Management
npm run synth:dev           # Preview dev infrastructure
npm run synth:prod          # Preview prod infrastructure
npm run cdk:diff:dev        # Show changes for dev
npm run cdk:diff:prod       # Show changes for prod
npm run cdk:bootstrap       # Bootstrap CDK
```

## Decision Matrix

### Choose Development Environment if:
- 💰 **Cost is primary concern**
- 🧪 **Development/testing workloads**
- 📚 **Learning TAK Server deployment**
- ⏰ **Occasional downtime acceptable**
- 🚀 **Rapid iteration needed**

### Choose Production Environment if:
- 🏢 **Production TAK Server workloads**
- 🔒 **High availability required**
- ⚡ **Auto-scaling needed**
- 👥 **Serving real users**
- 📊 **Monitoring/insights required**
- 💾 **Data protection critical**

## Service Endpoints

After successful deployment:

- **TAK Server Web UI**: `https://tak.{domain}`
- **TAK Service URL**: `https://ops.{domain}`
- **Certificate Enrollment**: `https://ops.{domain}:8446/Marti/api/tls`
- **API Admin**: `https://ops.{domain}:8443`
- **WebTAK Admin**: `https://ops.{domain}:8446`
- **Federation**: `https://ops.{domain}:9001`
- **Database**: Private endpoint (accessible via ECS tasks)

## TAK Server Ports

| Port | Protocol | Purpose | Access |
|------|----------|---------|--------|
| 80 | HTTP | Web interface | Public via NLB |
| 8089 | TCP | CoT (Cursor on Target) | Public via NLB |
| 8443 | HTTPS | API Admin | Public via NLB |
| 8446 | HTTPS | WebTAK Admin | Public via NLB |
| 9001 | TCP | Federation | Public via NLB |

## Troubleshooting Quick Fixes

### **Missing Base Infrastructure**
```bash
# Check if base stack exists
aws cloudformation describe-stacks --stack-name TAK-Demo-BaseInfra
```

### **Missing Authentication Infrastructure**
```bash
# Check if auth stack exists
aws cloudformation describe-stacks --stack-name TAK-Demo-AuthInfra
```

### **Docker Build Issues**
```bash
# Check Docker daemon is running
docker info

# Verify Dockerfiles exist
ls -la docker/tak-server/
```

### **Deployment Stuck**
```bash
# Check CloudFormation events
aws cloudformation describe-stack-events \
  --stack-name TAK-Demo-TakInfra \
  --max-items 10
```

### **Database Connection Issues**
```bash
# Check database status
aws rds describe-db-clusters \
  --db-cluster-identifier tak-demo-takinfra-database-dbcluster

# Check security groups
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*TakInfra*"
```

### **ECS Service Issues**
```bash
# Check ECS service status
aws ecs describe-services \
  --cluster TAK-Demo-BaseInfra \
  --services TAK-Demo-TakInfra-TakServer

# Check ECS task logs
aws logs describe-log-groups \
  --log-group-name-prefix "TakServer-takserver"
```

### **Access TAK Admin Certificate**
```bash
# Development environment
aws secretsmanager get-secret-value --secret-id "TAK-Dev-TakInfra/TAK-Server/Admin-Cert" --query SecretString --output text > admin-cert.p12

# Production environment
aws secretsmanager get-secret-value --secret-id "TAK-Prod-TakInfra/TAK-Server/Admin-Cert" --query SecretString --output text > admin-cert.p12
```

## Quick Links

- **[Main README](../README.md)** - Complete project overview
- **[Deployment Guide](DEPLOYMENT_GUIDE.md)** - Detailed deployment instructions
- **[Configuration Guide](PARAMETERS.md)** - Complete configuration reference
- **[Architecture Guide](ARCHITECTURE.md)** - Technical architecture details