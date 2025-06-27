/**
 * Unit tests for TAK Infrastructure Stack
 */
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { TakInfraStack } from '../../lib/tak-infra-stack';
import { MOCK_CONFIGS } from '../__fixtures__/mock-configs';

describe('TakInfraStack', () => {
  test('should create stack with dev-test configuration', () => {
    const app = new App();
    const stack = new TakInfraStack(app, 'TestTakInfraStack', {
      environment: 'dev-test',
      envConfig: MOCK_CONFIGS.DEV_TEST
    });
    
    const template = Template.fromStack(stack);
    expect(template).toBeDefined();
    
    // Verify key resources are created
    template.resourceCountIs('AWS::RDS::DBCluster', 1);
    template.resourceCountIs('AWS::EFS::FileSystem', 1);
    template.resourceCountIs('AWS::ElasticLoadBalancingV2::LoadBalancer', 1);
  });

  test('should create stack with prod configuration', () => {
    const app = new App();
    const stack = new TakInfraStack(app, 'TestTakInfraStack', {
      environment: 'prod',
      envConfig: MOCK_CONFIGS.PROD
    });
    
    const template = Template.fromStack(stack);
    expect(template).toBeDefined();
    
    // Verify production settings
    template.hasResourceProperties('AWS::RDS::DBCluster', {
      DeletionProtection: true
    });
  });

  test('should validate configuration structure', () => {
    const config = MOCK_CONFIGS.DEV_TEST;
    
    expect(config.stackName).toBeDefined();
    expect(config.database).toBeDefined();
    expect(config.ecs).toBeDefined();
    expect(config.takserver).toBeDefined();
    expect(config.ecr).toBeDefined();
    expect(config.general).toBeDefined();
  });
});