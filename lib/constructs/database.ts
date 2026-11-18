/**
 * Database Construct - CDK implementation of the PostgreSQL database for TAK Server
 */
import { Construct } from 'constructs';
import {
  aws_rds as rds,
  aws_ec2 as ec2,
  aws_secretsmanager as secretsmanager,
  aws_iam as iam,
  aws_kms as kms,
  aws_logs as logs,
  Annotations,
  Duration,
  RemovalPolicy
} from 'aws-cdk-lib';
import type { ContextEnvironmentConfig } from '../stack-config';
import type { InfrastructureConfig } from '../construct-configs';
import { DATABASE_CONSTANTS } from '../utils/constants';
import { resolveProvisionedInstanceClass } from '../utils/db-instance-class';

/**
 * Properties for the Database construct
 */
export interface DatabaseProps {
  /**
   * Environment type ('prod' | 'dev-test')
   */
  environment: 'prod' | 'dev-test';

  /**
   * Full stack name (e.g., 'TAK-Demo-TakInfra')
   */
  stackName: string;

  /**
   * Context-based environment configuration (direct from cdk.json)
   */
  contextConfig: ContextEnvironmentConfig;

  /**
   * Infrastructure configuration (VPC, KMS, security groups)
   */
  infrastructure: InfrastructureConfig;

  /**
   * Security groups for database access
   */
  securityGroups: ec2.SecurityGroup[];
}

/**
 * CDK construct for the PostgreSQL database cluster for TAK Server
 */
export class Database extends Construct {
  /**
   * The master secret for database access
   */
  public readonly masterSecret: secretsmanager.Secret;

  /**
   * The RDS database cluster
   */
  public readonly cluster: rds.DatabaseCluster;

  /**
   * The database hostname
   */
  public readonly hostname: string;

  /**
   * The database reader endpoint hostname (for read replicas)
   */
  public readonly readerEndpoint: string;

  constructor(scope: Construct, id: string, props: DatabaseProps) {
    super(scope, id);

    // Validate required database configuration
    if (!props.contextConfig.database) {
      throw new Error('Database configuration is required when using Database construct');
    }
    const dbConfig = props.contextConfig.database;

    // Derive environment-specific values from context (matches reference pattern)
    const isHighAvailability = props.environment === 'prod';
    const removalPolicy = props.contextConfig.general?.removalPolicy === 'RETAIN' ? 
      RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;
    const enableMonitoring = dbConfig.monitoringInterval > 0;

    // Create the master secret
    this.masterSecret = new secretsmanager.Secret(this, 'DBMasterSecret', {
      description: `${id}: PostgreSQL Master Password`,
      secretName: `${props.stackName}/Database/Master-Password`,
      encryptionKey: props.infrastructure.kmsKey,
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: DATABASE_CONSTANTS.USERNAME }),
        generateStringKey: 'password',
        excludePunctuation: true,
        passwordLength: DATABASE_CONSTANTS.PASSWORD_LENGTH
      }
    });

    // Create the monitoring role
    const monitoringRole = new iam.Role(this, 'DBMonitoringRole', {
      assumedBy: new iam.ServicePrincipal('monitoring.rds.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonRDSEnhancedMonitoringRole')
      ],
      path: '/'
    });

    // Create subnet group
    const subnetGroup = new rds.SubnetGroup(this, 'DBSubnetGroup', {
      description: `${id} database subnet group`,
      vpc: props.infrastructure.vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS
      }
    });

    // Create parameter group for PostgreSQL
    const engineVersionString = dbConfig.engineVersion || '17.4';
    // aws-cdk-lib does not yet ship a named AuroraPostgresEngineVersion constant for
    // PostgreSQL 18.x, so use the `.of()` escape hatch for that major version.
    const engineVersion = engineVersionString.startsWith('18') ?
      rds.AuroraPostgresEngineVersion.of(engineVersionString, '18') :
      engineVersionString.startsWith('17') ?
      rds.AuroraPostgresEngineVersion.VER_17_4 :
      rds.AuroraPostgresEngineVersion.VER_16_6;
    // PostgreSQL 18 turned `log_connections` from a boolean into a comma-separated list of
    // granular event types (receipt, authentication, authorization, setup_durations, or all/none).
    // Pre-18 engines still expect the boolean-style '1'.
    const isPostgres18OrLater = engineVersionString.startsWith('18');
    const parameterGroup = new rds.ParameterGroup(this, 'DBParameterGroup', {
      engine: rds.DatabaseClusterEngine.auroraPostgres({
        version: engineVersion
      }),
      description: `${id} cluster parameter group`,
      parameters: {
        'shared_preload_libraries': 'pg_stat_statements',
        'log_statement': 'all',
        'log_min_duration_statement': '1000',
        'log_connections': isPostgres18OrLater ? 'all' : '1',
        'log_disconnections': '1'
      }
    });

    // Create the database cluster with conditional configuration for serverless vs provisioned
    const isServerless = dbConfig.instanceClass === 'db.serverless';
    // Aurora storage type. Tri-state on purpose:
    //   - unset (`ioOptimized` not in the config): send nothing to CloudFormation, so an
    //     existing cluster keeps whatever storage type it has (the prod profile relies on this);
    //   - true: Aurora I/O-Optimized (`aurora-iopt1`), no per-request I/O charge;
    //   - false: Aurora Standard (`aurora`). Note AWS only allows moving from I/O-Optimized back
    //     to Standard once every 30 days, so do not toggle this from a pipeline.
    const storageType = dbConfig.ioOptimized === undefined ?
      undefined :
      dbConfig.ioOptimized ? rds.DBClusterStorageType.AURORA_IOPT1 : rds.DBClusterStorageType.AURORA;
    
    if (isServerless) {
      // Aurora Serverless v2 configuration
      this.cluster = new rds.DatabaseCluster(this, 'DBCluster', {
        engine: rds.DatabaseClusterEngine.auroraPostgres({
          version: engineVersion
        }),
        credentials: rds.Credentials.fromSecret(this.masterSecret),
        defaultDatabaseName: DATABASE_CONSTANTS.DEFAULT_DATABASE_NAME,
        port: DATABASE_CONSTANTS.PORT,
        serverlessV2MinCapacity: dbConfig.serverlessV2MinCapacity ?? 2.0,
        serverlessV2MaxCapacity: dbConfig.serverlessV2MaxCapacity ?? 8,
        writer: rds.ClusterInstance.serverlessV2('writer', {
          enablePerformanceInsights: dbConfig.enablePerformanceInsights,
          performanceInsightRetention: dbConfig.enablePerformanceInsights ?
            rds.PerformanceInsightRetention.MONTHS_6 :
            undefined
        }),
        readers: dbConfig.instanceCount > 1 ? 
          Array.from({ length: dbConfig.instanceCount - 1 }, (_, i) => 
            rds.ClusterInstance.serverlessV2(`reader${i + 1}`, {
              enablePerformanceInsights: dbConfig.enablePerformanceInsights,
              performanceInsightRetention: dbConfig.enablePerformanceInsights ?
                rds.PerformanceInsightRetention.MONTHS_6 :
                undefined
            })
          ) : [],
        parameterGroup,
        subnetGroup,
        vpc: props.infrastructure.vpc,
        vpcSubnets: {
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS
        },
        securityGroups: props.securityGroups,
        storageEncrypted: true,
        storageEncryptionKey: props.infrastructure.kmsKey,
        backup: {
          retention: Duration.days(props.contextConfig.database.backupRetentionDays)
        },
        deletionProtection: props.contextConfig.database.deleteProtection,
        removalPolicy: removalPolicy,
        cloudwatchLogsExports: props.contextConfig.database.enableCloudWatchLogs ? ['postgresql'] : undefined,
        cloudwatchLogsRetention: props.contextConfig.general.enableDetailedLogging ? 
          logs.RetentionDays.ONE_MONTH : 
          logs.RetentionDays.ONE_WEEK,
        monitoringRole: enableMonitoring ? monitoringRole : undefined,
        monitoringInterval: enableMonitoring ? Duration.seconds(dbConfig.monitoringInterval) : undefined,
        storageType,
        networkType: rds.NetworkType.DUAL
      });
    } else {
      // Provisioned instances configuration
      const resolved = resolveProvisionedInstanceClass(dbConfig.instanceClass);
      if (!resolved.recognised) {
        Annotations.of(this).addWarning(
          `database.instanceClass "${dbConfig.instanceClass}" is not a supported provisioned class ` +
          `(db.t4g.medium|large, db.r6g|r7g|r8g.large and up); using db.${resolved.instanceType}`
        );
      }
      const instanceType = new ec2.InstanceType(resolved.instanceType);

      this.cluster = new rds.DatabaseCluster(this, 'DBCluster', {
        engine: rds.DatabaseClusterEngine.auroraPostgres({
          version: engineVersion
        }),
        credentials: rds.Credentials.fromSecret(this.masterSecret),
        defaultDatabaseName: DATABASE_CONSTANTS.DEFAULT_DATABASE_NAME,
        port: DATABASE_CONSTANTS.PORT,
        writer: rds.ClusterInstance.provisioned('writer', {
          instanceType,
          enablePerformanceInsights: dbConfig.enablePerformanceInsights,
          performanceInsightRetention: dbConfig.enablePerformanceInsights ? 
            rds.PerformanceInsightRetention.MONTHS_6 : 
            undefined
        }),
        readers: props.contextConfig.database.instanceCount > 1 ? 
          Array.from({ length: props.contextConfig.database.instanceCount - 1 }, (_, i) => 
            rds.ClusterInstance.provisioned(`reader${i + 1}`, {
              instanceType,
              enablePerformanceInsights: props.contextConfig.database.enablePerformanceInsights,
              performanceInsightRetention: props.contextConfig.database.enablePerformanceInsights ? 
                rds.PerformanceInsightRetention.MONTHS_6 : 
                undefined
            })
          ) : [],
        // The RDS Data API is not supported on T-class instances. Clusters created while they
        // were Serverless v2 can have it switched on (for example through the console query
        // editor), and CloudFormation then fails the instance-class change and rolls back.
        // Nothing in this stack uses the Data API, so make sure it is off. Only set on this
        // branch: the Serverless v2 branch is left exactly as it was.
        enableDataApi: false,
        parameterGroup,
        subnetGroup,
        vpc: props.infrastructure.vpc,
        vpcSubnets: {
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS
        },
        securityGroups: props.securityGroups,
        storageEncrypted: true,
        storageEncryptionKey: props.infrastructure.kmsKey,
        backup: {
          retention: Duration.days(props.contextConfig.database.backupRetentionDays)
        },
        deletionProtection: props.contextConfig.database.deleteProtection,
        removalPolicy: removalPolicy,
        cloudwatchLogsExports: props.contextConfig.database.enableCloudWatchLogs ? ['postgresql'] : undefined,
        cloudwatchLogsRetention: props.contextConfig.general.enableDetailedLogging ? 
          logs.RetentionDays.ONE_MONTH : 
          logs.RetentionDays.ONE_WEEK,
        monitoringRole: enableMonitoring ? monitoringRole : undefined,
        monitoringInterval: enableMonitoring ? Duration.seconds(dbConfig.monitoringInterval) : undefined,
        storageType,
        networkType: rds.NetworkType.DUAL
      });
    }

    // Store the hostname and reader endpoint
    this.hostname = this.cluster.clusterEndpoint.hostname;
    this.readerEndpoint = this.cluster.clusterReadEndpoint.hostname;
  }
}