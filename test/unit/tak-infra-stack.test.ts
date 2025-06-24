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
      backupRetentionDays: 7,
      deleteProtection: false
    },
    ecs: { taskCpu: 1024, taskMemory: 2048, desiredCount: 1 },
    takserver: { hostname: 'tak', branding: 'generic', version: '5.4-RELEASE-19', useS3Config: false },
    general: { removalPolicy: 'DESTROY', enableDetailedLogging: true }
  };
  
  const stack = new TakInfraStack(app, 'TestTakInfraStack', { 
    environment: 'dev-test',
    envConfig
  });
  const template = Template.fromStack(stack);
  
  // Basic test to ensure stack synthesizes without errors
  expect(template).toBeDefined();
});