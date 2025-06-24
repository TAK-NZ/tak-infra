import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { TakInfraStack } from '../../lib/tak-infra-stack';

test('TakInfraStack creates successfully', () => {
  const app = new cdk.App();
  const config = {
    stackName: 'Test',
    database: { instanceClass: 'db.serverless' },
    ecs: { taskCpu: 1024, taskMemory: 2048 },
    takserver: { hostname: 'tak', branding: 'generic' },
    general: { removalPolicy: 'DESTROY' }
  };
  const defaults = { project: 'TAK.NZ', component: 'TakInfra', region: 'ap-southeast-2' };
  
  const stack = new TakInfraStack(app, 'TestTakInfraStack', { config, defaults });
  const template = Template.fromStack(stack);
  
  // Basic test to ensure stack synthesizes without errors
  expect(template).toBeDefined();
});