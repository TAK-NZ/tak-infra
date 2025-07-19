import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { RemovalPolicy, StackProps, Fn, CfnOutput, Token } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';

// Construct imports
import { TakSecretsManager } from './constructs/secrets-manager';
import { Database } from './constructs/database';
import { Efs } from './constructs/efs';
import { SecurityGroups } from './constructs/security-groups';
import { Elb } from './constructs/elb';
import { Route53 } from './constructs/route53';
import { TakServer } from './constructs/tak-server';

// Utility imports
import { createBaseImportValue, BASE_EXPORT_NAMES, createAuthImportValue, AUTH_EXPORT_NAMES } from './cloudformation-imports';
import { ContextEnvironmentConfig } from './stack-config';
import { validateEnvType, validateStackName } from './utils';
import type { InfrastructureConfig, NetworkConfig, StorageConfig, SecretsConfig } from './construct-configs';

export interface TakInfraStackProps extends StackProps {
  environment: 'prod' | 'dev-test';
  envConfig: ContextEnvironmentConfig; // Environment configuration from context
}

/**
 * Main CDK stack for the TAK Server Infrastructure
 */
export class TakInfraStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: TakInfraStackProps) {
    super(scope, id, {
      ...props,
      description: 'TAK Server Infrastructure - Central TAK Communication Hub',
    });

    // Validate configuration early
    validateEnvType(props.environment);
    validateStackName(props.envConfig.stackName);

    // Use environment configuration directly (no complex transformations needed)
    const { envConfig } = props;
    
    // Extract configuration values directly from envConfig
    const stackNameComponent = envConfig.stackName; // This is the STACK_NAME part (e.g., "Dev")
    
    const isHighAvailability = props.environment === 'prod';
    const environmentLabel = props.environment === 'prod' ? 'Prod' : 'Dev-Test';
    const resolvedStackName = id;
    
    // Use computed values from configuration
    const enableHighAvailability = isHighAvailability;
    const enableDetailedLogging = envConfig.general.enableDetailedLogging;

    // Get runtime CloudFormation values for stack outputs and resource naming
    const stackName = Fn.ref('AWS::StackName');
    const region = cdk.Stack.of(this).region;

    // Configuration-based parameter resolution
    const takServerHostname = envConfig.takserver.hostname;
    const takServerBranding = envConfig.takserver.branding;
    const takServerVersion = envConfig.takserver.version;
    const useS3ConfigFile = envConfig.takserver.useS3TAKServerConfigFile;
    const enableEcsExec = envConfig.ecs.enableEcsExec ?? false;

    // =================
    // IMPORT BASE INFRASTRUCTURE RESOURCES
    // =================

    // Import KMS key from base-infra for secrets encryption
    const kmsKey = kms.Key.fromKeyArn(this, 'ImportedKmsKey', 
      Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.KMS_KEY))
    );

    // Import VPC from base-infra
    const vpc = ec2.Vpc.fromVpcAttributes(this, 'ImportedVpc', {
      vpcId: Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.VPC_ID)),
      availabilityZones: [region + 'a', region + 'b'],
      privateSubnetIds: [
        Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.SUBNET_PRIVATE_A)),
        Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.SUBNET_PRIVATE_B))
      ],
      publicSubnetIds: [
        Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.SUBNET_PUBLIC_A)),
        Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.SUBNET_PUBLIC_B))
      ]
    });

    // Import ECS cluster from base-infra
    const ecsCluster = ecs.Cluster.fromClusterAttributes(this, 'ImportedEcsCluster', {
      clusterName: `TAK-${stackNameComponent}-BaseInfra`,
      clusterArn: Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.ECS_CLUSTER)),
      vpc: vpc
    });

    // Import S3 bucket from base-infra
    const s3Bucket = s3.Bucket.fromBucketArn(this, 'ImportedS3Bucket',
      Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.S3_ENV_CONFIG))
    );
    
    // =================
    // SECRETS MANAGEMENT
    // =================

    // Create TAK Server secrets (admin certificate)
    const takSecrets = new TakSecretsManager(this, 'TakSecrets', {
      environment: props.environment,
      contextConfig: envConfig,
      kmsKey
    });
    
    // =================
    // CORE INFRASTRUCTURE
    // =================

    // =================
    // INFRASTRUCTURE RESOURCES (created first)
    // =================

    // Create security groups
    const securityGroups = new SecurityGroups(this, 'SecurityGroups', {
      vpc,
      stackNameComponent
    });

    // Infrastructure configuration
    const infrastructure: InfrastructureConfig = {
      vpc,
      ecsSecurityGroup: securityGroups.takServer,
      ecsCluster,
      kmsKey
    };

    // Create database
    const database = new Database(this, 'Database', {
      environment: props.environment,
      stackName: resolvedStackName,
      contextConfig: envConfig,
      infrastructure,
      securityGroups: [securityGroups.database]
    });

    // Create EFS
    const efs = new Efs(this, 'Efs', {
      environment: props.environment,
      contextConfig: envConfig,
      infrastructure,
      efsSecurityGroup: securityGroups.efs
    });

    // Create load balancer
    const loadBalancer = new Elb(this, 'LoadBalancer', {
      environment: props.environment,
      contextConfig: envConfig,
      infrastructure,
      network: {
        hostedZoneId: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.HOSTED_ZONE_ID),
        hostedZoneName: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.HOSTED_ZONE_NAME),
        sslCertificateArn: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.CERTIFICATE_ARN),
        hostname: takServerHostname
      },
      nlbSecurityGroup: securityGroups.nlb
    });

    // =================
    // DNS RESOURCES (depends on Load Balancer)
    // =================

    // Create Route53 DNS records
    const route53 = new Route53(this, 'Route53', {
      environment: props.environment,
      contextConfig: envConfig,
      network: {
        hostedZoneId: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.HOSTED_ZONE_ID),
        hostedZoneName: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.HOSTED_ZONE_NAME),
        sslCertificateArn: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.CERTIFICATE_ARN),
        hostname: takServerHostname
      },
      takLoadBalancer: loadBalancer.loadBalancer
    });

    // =================
    // APPLICATION RESOURCES (depends on Infrastructure + DNS)
    // =================

    // Storage configuration
    const storage: StorageConfig = {
      s3: {
        configBucket: s3Bucket,
        envFileUri: useS3ConfigFile ? `s3://${s3Bucket.bucketName}/takserver-config.env` : undefined,
        envFileKey: useS3ConfigFile ? 'takserver-config.env' : undefined
      },
      efs: {
        fileSystemId: efs.fileSystem.fileSystemId,
        takCertsAccessPointId: efs.takCertsAccessPoint.accessPointId,
        letsEncryptAccessPointId: efs.letsEncryptAccessPoint.accessPointId,
        takConfigAccessPointId: efs.takConfigAccessPoint.accessPointId
      }
    };

    // Import LDAP service account secret from auth-infra
    const ldapServiceAccountSecret = secretsmanager.Secret.fromSecretCompleteArn(
      this, 'ImportedLdapSecret',
      Fn.importValue(createAuthImportValue(stackNameComponent, AUTH_EXPORT_NAMES.LDAP_SERVICE_USER_SECRET))
    );

    // Secrets configuration
    const secrets: SecretsConfig = {
      database: database.masterSecret,
      takserver: {
        adminCertificate: takSecrets.adminCertificate,
        federateCACertificate: takSecrets.federateCACertificate,
        ldapServiceAccount: ldapServiceAccountSecret,
        oauthConfig: undefined // Will be set if OAuth is configured
      }
    };

    // Determine container image strategy
    const usePreBuiltImages = this.node.tryGetContext('usePreBuiltImages') ?? false;
    const takImageTag = this.node.tryGetContext('takImageTag');
    
    let containerImageUri: string | undefined;
    if (usePreBuiltImages && takImageTag) {
      // Get ECR repository ARN from BaseInfra and extract repository name
      const ecrRepoArn = Fn.importValue(createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.ECR_REPO));
      // Extract repository name from ARN (format: arn:aws:ecr:region:account:repository/name)
      const ecrRepoName = Fn.select(1, Fn.split('/', ecrRepoArn));
      containerImageUri = `${this.account}.dkr.ecr.${this.region}.amazonaws.com/${Token.asString(ecrRepoName)}:${takImageTag}`;
    }

    // Create ECS service
    const takServerService = new TakServer(this, 'TakServer', {
      environment: props.environment,
      contextConfig: envConfig,
      infrastructure,
      storage,
      secrets,
      network: {
        hostedZoneId: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.HOSTED_ZONE_ID),
        hostedZoneName: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.HOSTED_ZONE_NAME),
        sslCertificateArn: createBaseImportValue(stackNameComponent, BASE_EXPORT_NAMES.CERTIFICATE_ARN),
        hostname: takServerHostname,
        databaseHostname: database.hostname,
        loadBalancer: loadBalancer.loadBalancer
      },
      targetGroups: loadBalancer.targetGroups,
      takFqdn: route53.takFqdn,
      database: database.cluster,
      containerImageUri
    });
    
    // =================
    // STACK OUTPUTS
    // =================

    // TAK Server URL
    new CfnOutput(this, 'TakServerUrl', {
      value: route53.getTakUrl(),
      description: 'TAK Server HTTPS URL',
      exportName: `${resolvedStackName}-TakServerUrl`
    });

    // TAK Service URL
    new CfnOutput(this, 'TakServiceUrl', {
      value: route53.getServiceUrl(),
      description: 'TAK Service URL',
      exportName: `${resolvedStackName}-TakServiceUrl`
    });

    // TAK Server certificate enrollment URL
    new CfnOutput(this, 'TakCertEnrollment', {
      value: route53.getCertEnrollmentUrl(),
      description: 'TAK Server certificate enrollment URL',
      exportName: `${resolvedStackName}-TakCertEnrollment`
    });

    // TAK Server FQDN
    new CfnOutput(this, 'TakServerFqdn', {
      value: route53.takFqdn,
      description: 'TAK Server Fully Qualified Domain Name',
      exportName: `${resolvedStackName}-TakServerFqdn`
    });

    // Load Balancer DNS Name
    new CfnOutput(this, 'LoadBalancerDnsName', {
      value: loadBalancer.dnsName,
      description: 'Network Load Balancer DNS Name',
      exportName: `${resolvedStackName}-LoadBalancerDnsName`
    });

    // Database endpoint
    new CfnOutput(this, 'DatabaseEndpoint', {
      value: database.cluster.clusterEndpoint.hostname,
      description: 'PostgreSQL Aurora cluster endpoint',
      exportName: `${resolvedStackName}-DatabaseEndpoint`
    });

    // EFS file system ID
    new CfnOutput(this, 'EfsFileSystemId', {
      value: efs.fileSystem.fileSystemId,
      description: 'EFS File System ID',
      exportName: `${resolvedStackName}-EfsFileSystemId`
    });

    // TAK Server Admin Certificate Secret ARN
    new CfnOutput(this, 'TakAdminCertSecretArn', {
      value: takSecrets.adminCertificate.secretArn,
      description: 'TAK Server Admin Certificate (p12) Secret ARN',
      exportName: `${resolvedStackName}-TakAdminCertSecretArn`
    });
    
    // TAK Server Federate CA Certificate Secret ARN
    new CfnOutput(this, 'TakFederateCACertSecretArn', {
      value: takSecrets.federateCACertificate.secretArn,
      description: 'TAK Server Federate CA Certificate (PEM) Secret ARN',
      exportName: `${resolvedStackName}-TakFederateCACertSecretArn`
    });

    // TAK Service Name (hostname without https://)
    new CfnOutput(this, 'TakServiceName', {
      value: route53.serviceFqdn,
      description: 'TAK Service fully qualified hostname (without https://)',
      exportName: `${resolvedStackName}-TakServiceName`
    });
  }
}