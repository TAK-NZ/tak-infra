/**
 * Test suite for Database construct
 */
import { App, Stack } from 'aws-cdk-lib';
import { Annotations, Match, Template } from 'aws-cdk-lib/assertions';
import { Database } from '../../../lib/constructs/database';
import { CDKTestHelper } from '../../__helpers__/cdk-test-utils';
import { MOCK_CONFIGS } from '../../__fixtures__/mock-configs';

describe('Database Construct', () => {
  let app: App;
  let stack: Stack;
  let infrastructureConfig: any;
  let securityGroups: any[];

  beforeEach(() => {
    ({ app, stack } = CDKTestHelper.createTestStack());
    infrastructureConfig = CDKTestHelper.createMockInfrastructure(stack);
    securityGroups = [infrastructureConfig.ecsSecurityGroup];
  });

  test('should throw error when database config is missing', () => {
    const configWithoutDb = {
      ...MOCK_CONFIGS.DEV_TEST,
      database: undefined
    } as any;

    expect(() => {
      new Database(stack, 'TestDB', {
        environment: 'dev-test',
        stackName: 'TestStack',
        contextConfig: configWithoutDb,
        infrastructure: infrastructureConfig,
        securityGroups
      });
    }).toThrow('Database configuration is required when using Database construct');
  });

  test('should create serverless database cluster', () => {
    const database = new Database(stack, 'TestDB', {
      environment: 'dev-test',
      stackName: 'TestStack',
      contextConfig: MOCK_CONFIGS.SERVERLESS,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    expect(database.cluster).toBeDefined();
    expect(database.masterSecret).toBeDefined();
    expect(database.hostname).toBeDefined();
    expect(database.readerEndpoint).toBeDefined();

    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::RDS::DBCluster', {
      Engine: 'aurora-postgresql',
      DatabaseName: 'takserver'
    });
  });

  test('should create provisioned database cluster', () => {
    const database = new Database(stack, 'TestDB', {
      environment: 'prod',
      stackName: 'TestStack',
      contextConfig: MOCK_CONFIGS.PROD,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    expect(database.cluster).toBeDefined();
    
    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::RDS::DBCluster', {
      Engine: 'aurora-postgresql',
      DeletionProtection: true
    });
  });

  test('should create secrets with proper naming', () => {
    const database = new Database(stack, 'TestDB', {
      environment: 'dev-test',
      stackName: 'TAK-Demo-TakInfra',
      contextConfig: MOCK_CONFIGS.DEV_TEST,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::SecretsManager::Secret', {
      Name: 'TAK-Demo-TakInfra/Database/Master-Password'
    });
  });

  test('should apply custom engine version to the cluster', () => {
    const customConfig = {
      ...MOCK_CONFIGS.DEV_TEST,
      database: {
        ...MOCK_CONFIGS.DEV_TEST.database,
        engineVersion: '17.4'
      }
    };

    new Database(stack, 'TestDB', {
      environment: 'dev-test',
      stackName: 'TestStack',
      contextConfig: customConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::RDS::DBCluster', {
      EngineVersion: '17.4'
    });
  });

  test('should size provisioned instances from a large instance class', () => {
    const largeConfig = {
      ...MOCK_CONFIGS.PROD,
      database: {
        ...MOCK_CONFIGS.PROD.database,
        instanceClass: 'db.t4g.large'
      }
    };

    new Database(stack, 'TestDB', {
      environment: 'prod',
      stackName: 'TestStack',
      contextConfig: largeConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::RDS::DBInstance', {
      DBInstanceClass: 'db.t4g.large'
    });
  });

  test('should provision the configured number of reader instances', () => {
    const multiReaderConfig = {
      ...MOCK_CONFIGS.PROD,
      database: {
        ...MOCK_CONFIGS.PROD.database,
        instanceCount: 3
      }
    };

    new Database(stack, 'TestDB', {
      environment: 'prod',
      stackName: 'TestStack',
      contextConfig: multiReaderConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    const template = Template.fromStack(stack);
    // 1 writer + 2 readers for instanceCount: 3
    template.resourceCountIs('AWS::RDS::DBInstance', 3);
  });

  test('should omit enhanced monitoring properties when monitoring is disabled', () => {
    const noMonitoringConfig = {
      ...MOCK_CONFIGS.DEV_TEST,
      database: {
        ...MOCK_CONFIGS.DEV_TEST.database,
        monitoringInterval: 0
      }
    };

    new Database(stack, 'TestDB', {
      environment: 'dev-test',
      stackName: 'TestStack',
      contextConfig: noMonitoringConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    const template = Template.fromStack(stack);
    const instances = template.findResources('AWS::RDS::DBInstance');
    const writer = Object.values(instances)[0] as { Properties: Record<string, unknown> };
    expect(writer.Properties.MonitoringInterval).toBeUndefined();
    expect(writer.Properties.MonitoringRoleArn).toBeUndefined();
  });

  describe('RDS Data API', () => {
    test('is switched off on a provisioned cluster (unsupported on T-class instances)', () => {
      new Database(stack, 'TestDB', {
        environment: 'prod',
        stackName: 'TestStack',
        contextConfig: MOCK_CONFIGS.PROD,
        infrastructure: infrastructureConfig,
        securityGroups
      });
      const template = Template.fromStack(stack);
      template.hasResourceProperties('AWS::RDS::DBCluster', { EnableHttpEndpoint: false });
    });

    test('is left untouched on a Serverless v2 cluster', () => {
      new Database(stack, 'TestDB', {
        environment: 'dev-test',
        stackName: 'TestStack',
        contextConfig: MOCK_CONFIGS.SERVERLESS,
        infrastructure: infrastructureConfig,
        securityGroups
      });
      const template = Template.fromStack(stack);
      const cluster = Object.values(template.findResources('AWS::RDS::DBCluster'))[0] as { Properties: Record<string, unknown> };
      expect(cluster.Properties.EnableHttpEndpoint).toBeUndefined();
    });
  });

  describe('PostgreSQL statement logging', () => {
    test('logs DDL only, not every statement (CoT INSERTs would otherwise dominate the log)', () => {
      new Database(stack, 'TestDB', {
        environment: 'dev-test',
        stackName: 'TestStack',
        contextConfig: MOCK_CONFIGS.DEV_TEST,
        infrastructure: infrastructureConfig,
        securityGroups
      });
      const template = Template.fromStack(stack);
      template.hasResourceProperties('AWS::RDS::DBClusterParameterGroup', {
        Parameters: Match.objectLike({
          log_statement: 'ddl',
          log_min_duration_statement: '1000'
        })
      });
    });
  });

  describe('Aurora storage type (ioOptimized)', () => {
    const withIoOptimized = (base: any, value: boolean | undefined) => ({
      ...base,
      database: { ...base.database, ioOptimized: value }
    });
    const clusterProps = () => {
      const template = Template.fromStack(stack);
      return (Object.values(template.findResources('AWS::RDS::DBCluster'))[0] as { Properties: Record<string, unknown> }).Properties;
    };
    const build = (config: any, environment: 'prod' | 'dev-test') =>
      new Database(stack, 'TestDB', {
        environment,
        stackName: 'TestStack',
        contextConfig: config,
        infrastructure: infrastructureConfig,
        securityGroups
      });

    test('true selects Aurora I/O-Optimized on a provisioned cluster', () => {
      build(withIoOptimized(MOCK_CONFIGS.PROD, true), 'prod');
      expect(clusterProps().StorageType).toBe('aurora-iopt1');
    });

    test('true also applies to a Serverless v2 cluster', () => {
      build(withIoOptimized(MOCK_CONFIGS.SERVERLESS, true), 'dev-test');
      expect(clusterProps().StorageType).toBe('aurora-iopt1');
    });

    test('false explicitly selects Aurora Standard', () => {
      build(withIoOptimized(MOCK_CONFIGS.PROD, false), 'prod');
      expect(clusterProps().StorageType).toBe('aurora');
    });

    test('unset sends NO storage type, so an existing cluster keeps whatever it has', () => {
      build(withIoOptimized(MOCK_CONFIGS.PROD, undefined), 'prod');
      expect(clusterProps().StorageType).toBeUndefined();
    });
  });

  describe('provisioned instance classes', () => {
    const build = (instanceClass: string) =>
      new Database(stack, 'TestDB', {
        environment: 'prod',
        stackName: 'TestStack',
        contextConfig: {
          ...MOCK_CONFIGS.PROD,
          database: { ...MOCK_CONFIGS.PROD.database, instanceClass }
        },
        infrastructure: infrastructureConfig,
        securityGroups
      });

    test('db.r6g.large is honoured (was silently mapped to a T4G before)', () => {
      build('db.r6g.large');
      Template.fromStack(stack).hasResourceProperties('AWS::RDS::DBInstance', { DBInstanceClass: 'db.r6g.large' });
    });

    test('db.t4g.medium is honoured', () => {
      build('db.t4g.medium');
      Template.fromStack(stack).hasResourceProperties('AWS::RDS::DBInstance', { DBInstanceClass: 'db.t4g.medium' });
    });

    test('a supported class produces no synth warning', () => {
      build('db.t4g.large');
      Annotations.fromStack(stack).hasNoWarning('*', Match.stringLikeRegexp('not a supported provisioned class'));
    });

    test('an unsupported class keeps the old T4G fallback and says so with a synth warning', () => {
      build('db.t4g.small');
      Template.fromStack(stack).hasResourceProperties('AWS::RDS::DBInstance', { DBInstanceClass: 'db.t4g.medium' });
      Annotations.fromStack(stack).hasWarning('*', Match.stringLikeRegexp('db.t4g.small.*not a supported provisioned class.*db.t4g.medium'));
    });
  });
});
