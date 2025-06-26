import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { TakInfraStack } from '../../lib/tak-infra-stack';
import { ContextEnvironmentConfig } from '../../lib/stack-config';

test('TakInfraStack creates successfully', () => {
  const app = new cdk.App();
  const envConfig: ContextEnvironmentConfig = {
    stackName: 'Test',
    database: { 
      instanceClass: 'db.serverless',
      instanceCount: 1,
      engineVersion: '17.4',
      allocatedStorage: 20,
      maxAllocatedStorage: 100,
      enablePerformanceInsights: false,
      monitoringInterval: 0,
      backupRetentionDays: 7,
      deleteProtection: false
    },
    ecs: { taskCpu: 1024, taskMemory: 2048, desiredCount: 1, enableDetailedLogging: true },
    takserver: { hostname: 'tak', servicename: 'ops', branding: 'generic', version: '5.4-RELEASE-19', useS3TAKServerConfigFile: false },
    ecr: { imageRetentionCount: 5, scanOnPush: false },
    general: { removalPolicy: 'DESTROY', enableDetailedLogging: true, enableContainerInsights: false }
  };
  
  const stack = new TakInfraStack(app, 'TestTakInfraStack', { 
    environment: 'dev-test',
    envConfig
  });
  const template = Template.fromStack(stack);
  
  // Basic test to ensure stack synthesizes without errors
  expect(template).toBeDefined();
});