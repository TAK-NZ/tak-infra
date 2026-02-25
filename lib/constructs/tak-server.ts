/**
 * TAK Server Construct - TAK Server container and ECS service configuration
 */
import { Construct } from 'constructs';
import {
  aws_ec2 as ec2,
  aws_ecs as ecs,
  aws_ecr_assets as ecrAssets,
  aws_elasticloadbalancingv2 as elbv2,
  aws_logs as logs,
  aws_secretsmanager as secretsmanager,
  aws_s3 as s3,
  aws_iam as iam,
  Duration,
  Stack,
  RemovalPolicy
} from 'aws-cdk-lib';
import type { ContextEnvironmentConfig } from '../stack-config';
import type { 
  InfrastructureConfig,
  SecretsConfig, 
  StorageConfig
} from '../construct-configs';
import { TAK_SERVER_PORTS } from '../utils/constants';
import { createAuthImportValue, AUTH_EXPORT_NAMES } from '../cloudformation-imports';
import { Fn } from 'aws-cdk-lib';

/**
 * Properties for the TAK Server construct
 */
export interface TakServerProps {
  /**
   * Environment type ('prod' | 'dev-test')
   */
  environment: 'prod' | 'dev-test';

  /**
   * Context-based environment configuration (direct from cdk.json)
   */
  contextConfig: ContextEnvironmentConfig;

  /**
   * Infrastructure configuration
   */
  infrastructure: InfrastructureConfig;

  /**
   * Secrets configuration
   */
  secrets: SecretsConfig;

  /**
   * Storage configuration
   */
  storage: StorageConfig;

  /**
   * Network configuration
   */
  network: {
    hostedZoneId: string;
    hostedZoneName: string;
    sslCertificateArn: string;
    hostname: string;
    databaseHostname: string;
    loadBalancer?: elbv2.ILoadBalancerV2;
  };

  /**
   * Target groups from load balancer
   */
  targetGroups: {
    http: elbv2.NetworkTargetGroup;
    cotTcp: elbv2.NetworkTargetGroup;
    apiAdmin: elbv2.NetworkTargetGroup;
    webtakAdmin: elbv2.NetworkTargetGroup;
    federation: elbv2.NetworkTargetGroup;
  };

  /**
   * TAK Server FQDN
   */
  takFqdn: string;

  /**
   * Database cluster for dependency management
   */
  database: any; // Using any to avoid circular import issues

  /**
   * Optional container image URI for pre-built images
   */
  containerImageUri?: string;
}

/**
 * CDK construct for the TAK Server container and ECS service
 */
export class TakServer extends Construct {
  /**
   * The ECS task definition for the TAK Server
   */
  public readonly taskDefinition: ecs.TaskDefinition;

  /**
   * The ECS service for TAK Server
   */
  public readonly ecsService: ecs.FargateService;

  constructor(scope: Construct, id: string, props: TakServerProps) {
    super(scope, id);

    // Derive environment-specific values from context (matches reference pattern)
    const isHighAvailability = props.environment === 'prod';
    const removalPolicy = props.contextConfig.general.removalPolicy === 'RETAIN' ? 
      RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;
    const logRetentionDays = props.contextConfig.general.enableDetailedLogging ? 30 : 7;

    // Create the log group
    const logGroup = new logs.LogGroup(this, 'ServerLogs', {
      logGroupName: `${id}-takserver`,
      retention: logRetentionDays,
      removalPolicy: RemovalPolicy.DESTROY
    });

    // Create task execution role
    const executionRole = new iam.Role(this, 'TaskExecutionRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonECSTaskExecutionRolePolicy')
      ]
    });

    // Add permissions to access secrets (following auth-infra pattern)
    props.secrets.database.grantRead(executionRole);
    if (props.secrets.takserver.ldapServiceAccount) {
      props.secrets.takserver.ldapServiceAccount.grantRead(executionRole);
    }
    if (props.secrets.takserver.oauthConfig) {
      props.secrets.takserver.oauthConfig.grantRead(executionRole);
    }
    if (props.secrets.takserver.adminCertificate) {
      props.secrets.takserver.adminCertificate.grantRead(executionRole);
    }
    if (props.secrets.takserver.federateCACertificate) {
      props.secrets.takserver.federateCACertificate.grantRead(executionRole);
    }

    // Add cross-stack secret access (corrected naming)
    const stackNameComponent = props.contextConfig.stackName;
    executionRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'secretsmanager:DescribeSecret',
        'secretsmanager:GetSecretValue'
      ],
      resources: [
        `arn:aws:secretsmanager:${Stack.of(this).region}:${Stack.of(this).account}:secret:TAK-${stackNameComponent}-TakInfra/*`,
        `arn:aws:secretsmanager:${Stack.of(this).region}:${Stack.of(this).account}:secret:TAK-${stackNameComponent}-AuthInfra/*`,
        `arn:aws:secretsmanager:${Stack.of(this).region}:${Stack.of(this).account}:secret:TAK-${stackNameComponent}-BaseInfra/*`
      ]
    }));

    // Grant explicit KMS permissions for secrets decryption
    props.infrastructure.kmsKey.grantDecrypt(executionRole);

    // Grant S3 access to execution role for environment files (needed during task initialization)
    if (props.storage.s3.envFileKey) {
      props.storage.s3.configBucket.grantRead(executionRole);
    }

    // Create task role
    const taskRole = new iam.Role(this, 'TaskRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
    });

    // Add ECS Exec and logging permissions to task role
    taskRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'ssmmessages:CreateControlChannel',
        'ssmmessages:CreateDataChannel',
        'ssmmessages:OpenControlChannel',
        'ssmmessages:OpenDataChannel'
      ],
      resources: ['*']
    }));

    taskRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'logs:CreateLogStream',
        'logs:DescribeLogStreams',
        'logs:PutLogEvents',
        'logs:DescribeLogGroups'
      ],
      resources: ['*']
    }));

    taskRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'cloudwatch:PutMetricData'
      ],
      resources: ['*']
    }));

    // Add EFS permissions for task role
    taskRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticfilesystem:ClientMount',
        'elasticfilesystem:ClientWrite',
        'elasticfilesystem:ClientRootAccess',
        'elasticfilesystem:DescribeMountTargets',
        'elasticfilesystem:DescribeFileSystems'
      ],
      resources: [
        `arn:aws:elasticfilesystem:${Stack.of(this).region}:${Stack.of(this).account}:file-system/${props.storage.efs.fileSystemId}`,
        `arn:aws:elasticfilesystem:${Stack.of(this).region}:${Stack.of(this).account}:access-point/${props.storage.efs.takCertsAccessPointId}`,
        `arn:aws:elasticfilesystem:${Stack.of(this).region}:${Stack.of(this).account}:access-point/${props.storage.efs.letsEncryptAccessPointId}`,
        `arn:aws:elasticfilesystem:${Stack.of(this).region}:${Stack.of(this).account}:access-point/${props.storage.efs.takConfigAccessPointId}`
      ]
    }));

    // Add TAK-specific permissions for admin certificate management (from CloudFormation)
    if (props.secrets.takserver.adminCertificate) {
      taskRole.addToPolicy(new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          'secretsmanager:PutSecretValue'
        ],
        resources: [
          `arn:aws:secretsmanager:${Stack.of(this).region}:${Stack.of(this).account}:secret:${Stack.of(this).stackName}/TAK-Server/Admin-Cert*`
        ]
      }));
    }
    
    // Add permissions for federate CA certificate management
    if (props.secrets.takserver.federateCACertificate) {
      taskRole.addToPolicy(new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          'secretsmanager:PutSecretValue'
        ],
        resources: [
          `arn:aws:secretsmanager:${Stack.of(this).region}:${Stack.of(this).account}:secret:${Stack.of(this).stackName}/TAK-Server/FederateCA*`
        ]
      }));
    }

    // Grant KMS permissions for secrets encryption and decryption
    props.infrastructure.kmsKey.grantEncryptDecrypt(taskRole);

    // Add ECS service update permissions (for self-service restarts)
    taskRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'ecs:UpdateService',
        'ecs:DescribeServices',
        'ecs:DescribeTasks'
      ],
      resources: [
        `arn:aws:ecs:${Stack.of(this).region}:${Stack.of(this).account}:service/${props.infrastructure.ecsCluster.clusterName}/${Stack.of(this).stackName}-TakServer`,
        `arn:aws:ecs:${Stack.of(this).region}:${Stack.of(this).account}:task/${props.infrastructure.ecsCluster.clusterName}/*`
      ]
    }));

    // Add ECS ListTasks permission (requires cluster and container instance access)
    taskRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['ecs:ListTasks'],
      resources: [
        `arn:aws:ecs:${Stack.of(this).region}:${Stack.of(this).account}:cluster/${props.infrastructure.ecsCluster.clusterName}`,
        `arn:aws:ecs:${Stack.of(this).region}:${Stack.of(this).account}:container-instance/${props.infrastructure.ecsCluster.clusterName}/*`
      ]
    }));

    // Add load balancer permissions for Certbot readiness checks
    taskRole.addToPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticloadbalancing:DescribeTargetGroups',
        'elasticloadbalancing:DescribeTargetHealth'
      ],
      resources: ['*']
    }));

    // Grant read access to S3 configuration bucket for environment files
    if (props.storage.s3.envFileKey) {
      props.storage.s3.configBucket.grantRead(taskRole);
    }

    // Create task definition
    this.taskDefinition = new ecs.FargateTaskDefinition(this, 'TaskDef', {
      cpu: props.contextConfig.ecs.taskCpu,
      memoryLimitMiB: props.contextConfig.ecs.taskMemory,
      executionRole,
      taskRole
    });

    // Add volumes for EFS
    this.taskDefinition.addVolume({
      name: 'tak-certs',
      efsVolumeConfiguration: {
        fileSystemId: props.storage.efs.fileSystemId,
        transitEncryption: 'ENABLED',
        authorizationConfig: {
          accessPointId: props.storage.efs.takCertsAccessPointId,
          iam: 'ENABLED'
        }
      }
    });

    this.taskDefinition.addVolume({
      name: 'letsencrypt',
      efsVolumeConfiguration: {
        fileSystemId: props.storage.efs.fileSystemId,
        transitEncryption: 'ENABLED',
        authorizationConfig: {
          accessPointId: props.storage.efs.letsEncryptAccessPointId,
          iam: 'ENABLED'
        }
      }
    });
    
    this.taskDefinition.addVolume({
      name: 'tak-config',
      efsVolumeConfiguration: {
        fileSystemId: props.storage.efs.fileSystemId,
        transitEncryption: 'ENABLED',
        authorizationConfig: {
          accessPointId: props.storage.efs.takConfigAccessPointId,
          iam: 'ENABLED'
        }
      }
    });

    // Use container image with fallback strategy
    let containerImage: ecs.ContainerImage;
    
    if (props.containerImageUri) {
      // Use pre-built image from registry
      containerImage = ecs.ContainerImage.fromRegistry(props.containerImageUri);
    } else {
      // Fall back to building Docker image asset
      const dockerfileName = `Dockerfile.${props.contextConfig.takserver.branding}`;
      const dockerImageAsset = new ecrAssets.DockerImageAsset(this, 'ServerDockerAsset', {
        directory: '.',
        file: `docker/tak-server/${dockerfileName}`,
        buildArgs: {
          TAK_VERSION: `takserver-docker-${props.contextConfig.takserver.version}`,
          ENVIRONMENT: props.contextConfig.stackName
        },
        platform: ecrAssets.Platform.LINUX_AMD64,
        // Exclude files that change frequently but don't affect the Docker build
        exclude: [
          'node_modules/**',
          'cdk.out/**',
          '.cdk.staging/**',
          '**/*.log',
          '**/*.tmp',
          '.git/**',
          '.vscode/**',
          '.idea/**',
          'test/**',
          'docs/**',
          'lib/**/*.js',
          'lib/**/*.d.ts',
          'lib/**/*.js.map',
          'bin/**/*.js',
          'bin/**/*.d.ts',
          '**/.DS_Store',
          '**/Thumbs.db',
          'backup/**',
          'reference/**',
          'cloudformation/**',
          'MIGRATION_PLAN.md',
          'CHANGELOG.md',
          'README.md'
        ]
      });
      containerImage = ecs.ContainerImage.fromDockerImageAsset(dockerImageAsset);
    }

    // Prepare container definition options
    let containerDefinitionOptions: ecs.ContainerDefinitionOptions = {
      image: containerImage,
      logging: ecs.LogDrivers.awsLogs({
        streamPrefix: 'takserver',
        logGroup
      }),
      environment: {
        LDAP_DN: Fn.importValue(createAuthImportValue(props.contextConfig.stackName, AUTH_EXPORT_NAMES.LDAP_BASE_DN)),
        LDAP_SECURE_URL: Fn.importValue(createAuthImportValue(props.contextConfig.stackName, AUTH_EXPORT_NAMES.LDAPS_ENDPOINT)),
        StackName: Stack.of(this).stackName,
        Environment: props.environment,
        ECS_Cluster_Name: props.infrastructure.ecsCluster.clusterName,
        ECS_Service_Name: `${Stack.of(this).stackName}-TakServer`,
        PostgresURL: `jdbc:postgresql://${props.network.databaseHostname}:5432/takserver`,
        TAKSERVER_QuickConnect_LetsEncrypt_Domain: `${props.contextConfig.takserver.servicename}.${Fn.importValue(props.network.hostedZoneName)}`,
        TAKSERVER_QuickConnect_LetsEncrypt_CertType: props.contextConfig.takserver.letsEncryptMode || 'staging',
        TAKSERVER_QuickConnect_LetsEncrypt_Email: props.contextConfig.takserver.letsEncryptEmail || 'admin@tak.nz',
        TAKSERVER_CoreConfig_Network_CloudwatchEnable: props.contextConfig.takserver.enableCloudWatchMetrics?.toString() || 'false',
        // LDAP Group Prefix Configuration
        ...(props.contextConfig.takserver.ldapGroupPrefix && {
          TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix: `cn=${props.contextConfig.takserver.ldapGroupPrefix}`,
          TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex: `cn=${props.contextConfig.takserver.ldapGroupPrefix}(.*?)(?:,|$)`
        }),
        // WebTAK Configuration
        TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak: (props.contextConfig.webtak?.enabled ?? false).toString(),
        TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak: (props.contextConfig.webtak?.enabled ?? false).toString(),
        // WebTAK OIDC Configuration
        ...(props.contextConfig.webtak?.enableOidc && props.secrets.takserver.webTakOidc && {
          TAKSERVER_CoreConfig_OAuth_UseTakServerLoginPage: (props.contextConfig.webtak?.useTakServerLoginPage ?? true).toString(),
          TAKSERVER_CoreConfig_OAuth_UsernameClaim: 'preferred_username',
          //TAKSERVER_CoreConfig_OAuth_OauthUseGroupCache: 'true',
          //TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts: 'false',
          TAKSERVER_CoreConfig_OAuthServer_Name: props.contextConfig.takserver.branding === 'tak-nz' ? 'TAK.NZ Account' : 'SSO Account',
          TAKSERVER_CoreConfig_OAuthServer_Scope: 'openid profile',
          TAKSERVER_CoreConfig_OAuthServer_Issuer: '/opt/tak/certs/files/oauth-public-key.pem',
          TAKSERVER_CoreConfig_OAuthServer_JWKS: props.secrets.takserver.webTakOidc.jwksUri,
          TAKSERVER_CoreConfig_OAuthServer_ClientId: props.secrets.takserver.webTakOidc.clientId,
          TAKSERVER_CoreConfig_OAuthServer_RedirectUri: `https://${props.contextConfig.takserver.servicename}.${Fn.importValue(props.network.hostedZoneName)}/login/redirect`,
          TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint: props.secrets.takserver.webTakOidc.authorizeUrl,
          TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint: props.secrets.takserver.webTakOidc.tokenUrl
          
        })
      },
      secrets: {
        PostgresUsername: ecs.Secret.fromSecretsManager(props.secrets.database, 'username'),
        PostgresPassword: ecs.Secret.fromSecretsManager(props.secrets.database, 'password'),
        ...(props.secrets.takserver.ldapServiceAccount && {
          LDAP_Username: ecs.Secret.fromSecretsManager(props.secrets.takserver.ldapServiceAccount, 'username'),
          LDAP_Password: ecs.Secret.fromSecretsManager(props.secrets.takserver.ldapServiceAccount, 'password')
        }),
        // WebTAK OIDC Client Secret
        ...(props.contextConfig.webtak?.enableOidc && props.secrets.takserver.webTakOidcClientSecret && {
          TAKSERVER_CoreConfig_OAuthServer_Secret: ecs.Secret.fromSecretsManager(props.secrets.takserver.webTakOidcClientSecret)
        })
      },
      healthCheck: {
        command: [
          'CMD-SHELL',
          'curl -ks --cert /opt/tak/certs/files/admin.pem --key /opt/tak/certs/files/admin.key --pass atakatak https://localhost:8443/actuator/health/readiness || exit 1'
        ],
        interval: Duration.seconds(5),      // Match target group settings
        timeout: Duration.seconds(2),       // Match target group settings
        retries: 2,                        // Match target group threshold
        startPeriod: Duration.seconds(240)  // Extended for TAK startup
      },
      essential: true
    };

    // Add environment files if S3 key is provided and useConfigFile is enabled
    if (props.storage.s3.envFileKey && props.contextConfig.takserver.useS3TAKServerConfigFile) {
      containerDefinitionOptions = {
        ...containerDefinitionOptions,
        environmentFiles: [
          ecs.EnvironmentFile.fromBucket(props.storage.s3.configBucket, props.storage.s3.envFileKey)
        ]
      };
    }

    const container = this.taskDefinition.addContainer('TakServer', containerDefinitionOptions);

    // Add port mappings for all TAK Server ports
    container.addPortMappings(
      { containerPort: TAK_SERVER_PORTS.HTTP, protocol: ecs.Protocol.TCP },
      { containerPort: TAK_SERVER_PORTS.HTTPS, protocol: ecs.Protocol.TCP },
      { containerPort: TAK_SERVER_PORTS.COT_TCP, protocol: ecs.Protocol.TCP },
      { containerPort: TAK_SERVER_PORTS.API_ADMIN, protocol: ecs.Protocol.TCP },
      { containerPort: TAK_SERVER_PORTS.WEBTAK_ADMIN, protocol: ecs.Protocol.TCP },
      { containerPort: TAK_SERVER_PORTS.FEDERATION, protocol: ecs.Protocol.TCP }
    );

    // Add mount points for EFS volumes
    container.addMountPoints({
      containerPath: '/opt/tak/certs/files',
      sourceVolume: 'tak-certs',
      readOnly: false
    });

    container.addMountPoints({
      containerPath: '/etc/letsencrypt',
      sourceVolume: 'letsencrypt',
      readOnly: false
    });
    
    container.addMountPoints({
      containerPath: '/opt/tak/persistent-config',
      sourceVolume: 'tak-config',
      readOnly: false
    });

    // Create ECS service with predictable name
    this.ecsService = new ecs.FargateService(this, 'Service', {
      serviceName: `${Stack.of(this).stackName}-TakServer`,
      cluster: props.infrastructure.ecsCluster,
      taskDefinition: this.taskDefinition,
      healthCheckGracePeriod: Duration.seconds(360),  // 6 minutes with readiness endpoint
      desiredCount: props.contextConfig.ecs.desiredCount,
      securityGroups: [props.infrastructure.ecsSecurityGroup],
      enableExecuteCommand: props.contextConfig.ecs.enableEcsExec,
      assignPublicIp: false,
      // Configure deployment to maintain availability
      minHealthyPercent: 100,  // Always use zero-downtime deployments
      maxHealthyPercent: 200,
      circuitBreaker: { rollback: true }
    });

    // Register service with all target groups
    props.targetGroups.http.addTarget(this.ecsService.loadBalancerTarget({
      containerName: 'TakServer',
      containerPort: TAK_SERVER_PORTS.HTTP
    }));

    props.targetGroups.cotTcp.addTarget(this.ecsService.loadBalancerTarget({
      containerName: 'TakServer',
      containerPort: TAK_SERVER_PORTS.COT_TCP
    }));

    props.targetGroups.apiAdmin.addTarget(this.ecsService.loadBalancerTarget({
      containerName: 'TakServer',
      containerPort: TAK_SERVER_PORTS.API_ADMIN
    }));

    props.targetGroups.webtakAdmin.addTarget(this.ecsService.loadBalancerTarget({
      containerName: 'TakServer',
      containerPort: TAK_SERVER_PORTS.WEBTAK_ADMIN
    }));

    props.targetGroups.federation.addTarget(this.ecsService.loadBalancerTarget({
      containerName: 'TakServer',
      containerPort: TAK_SERVER_PORTS.FEDERATION
    }));

    // Add explicit dependency on database cluster
    this.ecsService.node.addDependency(props.database);

    // No autoscaling - use fixed desired count from configuration
  }
}