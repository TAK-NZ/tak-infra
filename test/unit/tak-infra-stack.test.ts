/**
 * Unit tests for TAK Infrastructure Stack
 */
import { App } from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Template } from 'aws-cdk-lib/assertions';
import { TakInfraStack } from '../../lib/tak-infra-stack';
import { MOCK_CONFIGS } from '../__fixtures__/mock-configs';

// Prevent CDK from bundling real Lambda asset directories during unit tests
jest.spyOn(lambda.Code, 'fromAsset').mockReturnValue(lambda.Code.fromInline('exports.handler = async () => ({})') as any);

// Prevent CDK from hashing the Docker build context (slow filesystem walk) during unit tests
jest.mock('aws-cdk-lib/aws-ecr-assets', () => {
  const actual = jest.requireActual('aws-cdk-lib/aws-ecr-assets');
  return {
    ...actual,
    DockerImageAsset: jest.fn().mockImplementation((_scope: any, _id: any) => ({
      imageUri: 'mock-account.dkr.ecr.mock-region.amazonaws.com/mock-repo:mock-tag',
      repository: { repositoryUri: 'mock-repo', grantPull: jest.fn() },
      assetHash: 'mockhash',
      node: { id: _id, addDependency: jest.fn() }
    }))
  };
});

describe('TakInfraStack', () => {
  test('should create stack with dev-test configuration', () => {
    const app = new App();
    const stack = new TakInfraStack(app, 'TestTakInfraStack', {
      environment: 'dev-test',
      envConfig: MOCK_CONFIGS.DEV_TEST,
      env: { account: '123456789012', region: 'ap-southeast-2' }
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
      envConfig: MOCK_CONFIGS.PROD,
      env: { account: '123456789012', region: 'ap-southeast-2' }
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