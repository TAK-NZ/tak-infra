/**
 * Unit tests for TAK Infrastructure Stack
 */
import { App } from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Annotations, Match, Template } from 'aws-cdk-lib/assertions';
import { TakInfraStack, knowledgeBaseOutputSuffix } from '../../lib/tak-infra-stack';
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

  describe('Bedrock knowledge bases', () => {
    const build = (knowledgeBases?: string[]) => {
      const stack = new TakInfraStack(new App(), 'TAK-Test-TakInfra', {
        environment: 'dev-test',
        envConfig: { ...MOCK_CONFIGS.DEV_TEST, bedrock: { knowledgeBases } },
        env: { account: '123456789012', region: 'ap-southeast-2' }
      });
      return Template.fromStack(stack);
    };

    test('creates one knowledge base per configured name, reading the TAK Images bucket export', () => {
      const template = build(['nema-cdem', 'nzdf']);
      template.resourceCountIs('AWS::Bedrock::KnowledgeBase', 2);
      template.resourceCountIs('AWS::S3Vectors::Index', 2);
      template.hasResourceProperties('AWS::Bedrock::DataSource', {
        DataSourceConfiguration: {
          S3Configuration: { BucketArn: { 'Fn::ImportValue': 'TAK-DevTest-BaseInfra-S3TAKImagesArn' }, InclusionPrefixes: ['bedrock-kb/nzdf/'] }
        }
      });
    });

    test('outputs the knowledge base and data source IDs for setup-bedrock-agent.py', () => {
      const outputs = build(['nema-cdem']).toJSON().Outputs;
      expect(outputs.BedrockKbNemaCdemId.Export.Name).toBe('TAK-Test-TakInfra-BedrockKbNemaCdemId');
      expect(outputs.BedrockKbNemaCdemDataSourceId).toBeDefined();
    });

    describe('in a region without Bedrock Knowledge Bases', () => {
      const buildIn = (region: string, knowledgeBases: string[]) => {
        const stack = new TakInfraStack(new App(), 'TAK-Test-TakInfra', {
          environment: 'dev-test',
          envConfig: { ...MOCK_CONFIGS.DEV_TEST, bedrock: { knowledgeBases } },
          env: { account: '123456789012', region }
        });
        return { template: Template.fromStack(stack), annotations: Annotations.fromStack(stack) };
      };

      test('ap-southeast-6 creates no knowledge base and says so', () => {
        const { template, annotations } = buildIn('ap-southeast-6', ['nema-cdem']);
        template.resourceCountIs('AWS::Bedrock::KnowledgeBase', 0);
        template.resourceCountIs('AWS::Bedrock::DataSource', 0);
        template.resourceCountIs('AWS::S3Vectors::VectorBucket', 0);
        expect(Object.keys(template.toJSON().Outputs ?? {}).filter(k => k.startsWith('BedrockKb'))).toEqual([]);
        annotations.hasWarning('*', Match.stringLikeRegexp('Bedrock Knowledge Bases are not available in ap-southeast-6.*nema-cdem'));
      });

      test('no warning when no knowledge base is configured there', () => {
        const { annotations } = buildIn('ap-southeast-6', []);
        annotations.hasNoWarning('*', Match.stringLikeRegexp('Bedrock Knowledge Bases are not available'));
      });

      test('a supported region still creates them, without a warning', () => {
        const { template, annotations } = buildIn('ap-southeast-2', ['nema-cdem']);
        template.resourceCountIs('AWS::Bedrock::KnowledgeBase', 1);
        annotations.hasNoWarning('*', Match.stringLikeRegexp('Bedrock Knowledge Bases are not available'));
      });
    });

    test.each([[undefined], [[]]])('creates none when the list is %p', (list) => {
      const template = build(list as string[] | undefined);
      template.resourceCountIs('AWS::Bedrock::KnowledgeBase', 0);
      template.resourceCountIs('AWS::S3Vectors::VectorBucket', 0);
    });
  });

  test('knowledgeBaseOutputSuffix turns a knowledge base name into a PascalCase output suffix', () => {
    expect(knowledgeBaseOutputSuffix('nema-cdem')).toBe('NemaCdem');
    expect(knowledgeBaseOutputSuffix('nzdf')).toBe('Nzdf');
    expect(knowledgeBaseOutputSuffix('a-b.c')).toBe('ABC');
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
});