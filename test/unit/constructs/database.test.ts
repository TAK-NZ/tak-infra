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

  test('should handle custom engine version', () => {
    const customConfig = {
      ...MOCK_CONFIGS.DEV_TEST,
      database: {
        ...MOCK_CONFIGS.DEV_TEST.database,
        engineVersion: '16.6'
      }
    };

    const database = new Database(stack, 'TestDB', {
      environment: 'dev-test',
      stackName: 'TestStack',
      contextConfig: customConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    expect(database.cluster).toBeDefined();
  });

  test('should handle large instance type', () => {
    const largeConfig = {
      ...MOCK_CONFIGS.PROD,
      database: {
        ...MOCK_CONFIGS.PROD.database,
        instanceClass: 'db.t4g.large'
      }
    };

    const database = new Database(stack, 'TestDB', {
      environment: 'prod',
      stackName: 'TestStack',
      contextConfig: largeConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    expect(database.cluster).toBeDefined();
  });

  test('should handle multiple readers', () => {
    const multiReaderConfig = {
      ...MOCK_CONFIGS.PROD,
      database: {
        ...MOCK_CONFIGS.PROD.database,
        instanceCount: 3
      }
    };

    const database = new Database(stack, 'TestDB', {
      environment: 'prod',
      stackName: 'TestStack',
      contextConfig: multiReaderConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    expect(database.cluster).toBeDefined();
  });

  test('should handle monitoring disabled', () => {
    const noMonitoringConfig = {
      ...MOCK_CONFIGS.DEV_TEST,
      database: {
        ...MOCK_CONFIGS.DEV_TEST.database,
        monitoringInterval: 0
      }
    };

    const database = new Database(stack, 'TestDB', {
      environment: 'dev-test',
      stackName: 'TestStack',
      contextConfig: noMonitoringConfig,
      infrastructure: infrastructureConfig,
      securityGroups
    });

    expect(database.cluster).toBeDefined();
  });
});