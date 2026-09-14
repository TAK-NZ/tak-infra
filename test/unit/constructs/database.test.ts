/**
 * Test suite for Database construct
 */
import { App, Stack } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
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
});