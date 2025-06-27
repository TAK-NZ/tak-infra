# Let's Encrypt Lambda Migration Plan

## Overview

Migration from HTTP-01 challenge (in-container) to DNS-01 challenge (Lambda-based) for Let's Encrypt certificate management. This approach eliminates port 80 security risks while leveraging existing EFS infrastructure.

## Current State

- EFS file system already exists with `letsEncryptAccessPointId`
- Container mounts EFS at `/etc/letsencrypt`
- HTTP-01 challenge requires port 80 exposure
- Certificate management tied to container lifecycle

## Target Architecture

- Lambda function handles certificate generation/renewal via DNS-01 challenge
- Certificates stored in existing EFS (`/etc/letsencrypt`)
- EventBridge triggers daily certificate checks
- Container reads certificates from EFS (no changes to certificate consumption)
- Port 80 no longer required

## Implementation Plan

### Phase 1: Lambda Function Development

#### 1.1 Lambda Function Setup
- **Runtime**: Python 3.11
- **Memory**: 1GB
- **Timeout**: 15 minutes
- **VPC**: Same as ECS tasks for EFS access
- **EFS Mount**: `/mnt/efs` (maps to container's `/etc/letsencrypt`)

#### 1.2 IAM Permissions
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:GetChange"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite"
      ],
      "Resource": "arn:aws:elasticfilesystem:*:*:access-point/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService"
      ],
      "Resource": "arn:aws:ecs:*:*:service/*/*"
    }
  ]
}
```

#### 1.3 Dependencies
- `certbot`
- `certbot-dns-route53`
- `boto3`

### Phase 2: Certificate Management Logic

#### 2.1 Certificate Generation Flow
1. Check existing certificates in `/mnt/efs/live/{domain}/`
2. Validate certificate expiry (renew if <30 days remaining)
3. Use DNS-01 challenge with Route53
4. Store certificates in EFS at standard Let's Encrypt paths
5. Trigger ECS service deployment for certificate pickup

#### 2.2 Staging vs Production Logic
- Environment variable: `LETSENCRYPT_MODE` (staging/production)
- Staging: Use Let's Encrypt staging environment
- Production: Use Let's Encrypt production environment

#### 2.3 Error Handling
- Retry logic for DNS propagation delays
- CloudWatch logging for troubleshooting
- Graceful fallback (don't delete existing valid certificates)

### Phase 3: Event-Driven Automation

#### 3.1 EventBridge Rule
- **Schedule**: Daily at 02:00 UTC
- **Target**: Lambda function
- **Payload**: Domain and environment configuration

#### 3.2 Certificate Lifecycle
- Check certificate expiry before renewal attempts
- Implement same staging/production logic as current script
- Maintain certificate history in CloudWatch logs

### Phase 4: Container Modifications

#### 4.1 Remove HTTP-01 Challenge Code
**Files to modify:**
- `docker-container/scripts/start-tak.sh`: Remove `letsencrypt-request-cert.sh` execution
- `docker/tak-server/Dockerfile.*`: Remove certbot installation
- Remove `docker-container/scripts/letsencrypt-request-cert.sh`

**Keep unchanged:**
- Certificate reading logic in `start-tak.sh`
- PEM to JKS conversion logic
- EFS mount configuration

#### 4.2 Security Group Updates
- Remove port 80 ingress rules from load balancer
- Remove port 80 ingress rules from ECS security groups

### Phase 5: Migration Strategy

#### 5.1 Deployment Steps
1. **Deploy Lambda** (inactive)
   - Create Lambda function
   - Configure EFS access
   - Test certificate generation manually

2. **Parallel Testing**
   - Lambda generates certificates to EFS
   - Container continues using existing certificates
   - Validate certificate format and paths

3. **Container Updates**
   - Remove HTTP-01 challenge code
   - Remove port 80 security group rules
   - Deploy updated container

4. **Enable Automation**
   - Create EventBridge rule
   - Enable daily certificate checks

#### 5.2 Rollback Plan
- Re-enable HTTP-01 challenge code in container
- Re-add port 80 security group rules
- Disable Lambda EventBridge trigger

### Phase 6: Monitoring and Alerting

#### 6.1 CloudWatch Metrics
- Lambda execution success/failure
- Certificate expiry dates
- EFS mount health

#### 6.2 Alarms
- Lambda function failures
- Certificate expiry warnings (30 days)
- EFS mount failures

## Implementation Timeline

| Week | Phase | Tasks |
|------|-------|-------|
| 1 | Lambda Development | Function creation, EFS integration, DNS-01 implementation |
| 2 | Container Updates | Remove HTTP-01 code, security group updates |
| 3 | Automation Setup | EventBridge rules, monitoring, end-to-end testing |
| 4 | Production Deployment | Gradual rollout, monitoring, documentation |

## Operational Cost Estimate

### AWS Lambda
- **Executions**: 30/month (daily checks)
- **Duration**: ~2 minutes average per execution
- **Memory**: 1GB
- **Cost**: ~$0.05/month

### EventBridge
- **Rules**: 1 rule
- **Invocations**: 30/month
- **Cost**: ~$0.01/month

### Route53
- **DNS API Calls**: ~60/month (DNS-01 challenge)
- **Cost**: ~$0.02/month

### EFS (Existing)
- **Additional Storage**: Negligible (certificates ~10KB)
- **Additional Cost**: $0.00/month

### CloudWatch Logs
- **Log Storage**: ~10MB/month
- **Cost**: ~$0.01/month

### **Total Monthly Cost: ~$0.09/month**

### Annual Cost Comparison
- **Current Approach**: $0 (but security risk)
- **Lambda Approach**: ~$1.08/year
- **Security Benefit**: Eliminates port 80 exposure risk

## Risk Assessment

### Technical Risks
| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| EFS mount failure in Lambda | High | Low | Use existing access points, test thoroughly |
| DNS propagation delays | Medium | Medium | Implement retry logic with backoff |
| Certificate format issues | Medium | Low | Keep existing PEM→JKS conversion in container |
| Lambda cold starts | Low | High | Accept 30-60 second delay for renewals |

### Operational Risks
| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Certificate renewal failure | High | Low | CloudWatch alarms, manual fallback |
| ECS service restart issues | Medium | Low | Use existing proven restart mechanism |
| Route53 permissions | Medium | Low | Test IAM permissions thoroughly |

## Success Criteria

1. ✅ Certificates generated successfully via DNS-01 challenge
2. ✅ Port 80 no longer required for certificate management
3. ✅ Automatic certificate renewal working
4. ✅ Container startup time unchanged
5. ✅ Zero downtime during migration
6. ✅ Monitoring and alerting operational

## Rollback Criteria

- Lambda function fails for 3 consecutive days
- Certificate generation consistently fails
- EFS mount issues in Lambda
- Container cannot read certificates from EFS

## Post-Migration Benefits

1. **Security**: Eliminated port 80 exposure
2. **Reliability**: Certificate management independent of container lifecycle
3. **Scalability**: Serverless certificate management
4. **Cost**: Minimal operational cost increase (~$1/year)
5. **Maintenance**: Reduced container complexity
6. **Compliance**: Better alignment with AWS security best practices

## Dependencies

- Existing EFS file system and access points
- Route53 hosted zone for DNS-01 challenge
- ECS service restart permissions
- VPC configuration for Lambda EFS access

## Next Steps

1. Review and approve this migration plan
2. Create Lambda function development environment
3. Begin Phase 1 implementation
4. Schedule migration window for production deployment