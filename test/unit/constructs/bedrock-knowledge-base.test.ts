/**
 * Test suite for the BedrockKnowledgeBase construct (S3 Vectors storage)
 */
import { RemovalPolicy, Stack } from 'aws-cdk-lib';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { BedrockKnowledgeBase } from '../../../lib/constructs/bedrock-knowledge-base';
import { CDKTestHelper } from '../../__helpers__/cdk-test-utils';

describe('BedrockKnowledgeBase construct', () => {
  let stack: Stack;
  let bucket: s3.IBucket;
  let key: kms.IKey;

  const create = (name = 'nema-cdem', removalPolicy = RemovalPolicy.DESTROY) =>
    new BedrockKnowledgeBase(stack, `Kb-${name}`, { name, sourceBucket: bucket, sourceBucketKey: key, removalPolicy });

  beforeEach(() => {
    ({ stack } = CDKTestHelper.createTestStack());
    bucket = s3.Bucket.fromBucketArn(stack, 'Images', 'arn:aws:s3:::tak-images-bucket');
    key = kms.Key.fromKeyArn(stack, 'Key', 'arn:aws:kms:ap-southeast-2:123456789012:key/12345678-1234-1234-1234-123456789012');
  });

  test('creates a float32 1024-dimension cosine index named after the knowledge base', () => {
    create();
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::S3Vectors::VectorBucket', 1);
    template.hasResourceProperties('AWS::S3Vectors::Index', {
      IndexName: 'nema-cdem',
      DataType: 'float32',
      Dimension: 1024,
      DistanceMetric: 'cosine',
    });
  });

  test('marks the chunk text and metadata as non-filterable (2 KB filterable metadata limit)', () => {
    create();
    Template.fromStack(stack).hasResourceProperties('AWS::S3Vectors::Index', {
      MetadataConfiguration: { NonFilterableMetadataKeys: ['AMAZON_BEDROCK_TEXT', 'AMAZON_BEDROCK_METADATA'] },
    });
  });

  test('knowledge base uses S3 Vectors and Titan Embed Text v2 at 1024 dimensions', () => {
    create();
    Template.fromStack(stack).hasResourceProperties('AWS::Bedrock::KnowledgeBase', {
      Name: 'nema-cdem-s3v',
      KnowledgeBaseConfiguration: {
        Type: 'VECTOR',
        VectorKnowledgeBaseConfiguration: {
          EmbeddingModelArn: Match.anyValue(),
          EmbeddingModelConfiguration: {
            BedrockEmbeddingModelConfiguration: { Dimensions: 1024, EmbeddingDataType: 'FLOAT32' },
          },
        },
      },
      StorageConfiguration: {
        Type: 'S3_VECTORS',
        S3VectorsConfiguration: { IndexArn: { 'Fn::GetAtt': [Match.stringLikeRegexp('VectorIndex'), 'IndexArn'] } },
      },
    });
    const kb = Object.values(Template.fromStack(stack).findResources('AWS::Bedrock::KnowledgeBase'))[0] as any;
    expect(JSON.stringify(kb.Properties.KnowledgeBaseConfiguration)).toContain('amazon.titan-embed-text-v2:0');
  });

  test('data source reads only the bedrock-kb/<name>/ prefix of the source bucket', () => {
    create('nzdf');
    Template.fromStack(stack).hasResourceProperties('AWS::Bedrock::DataSource', {
      Name: 'nzdf-s3',
      DataSourceConfiguration: {
        Type: 'S3',
        S3Configuration: { BucketArn: 'arn:aws:s3:::tak-images-bucket', InclusionPrefixes: ['bedrock-kb/nzdf/'] },
      },
    });
  });

  test('knowledge base waits for the role and its policy (Bedrock validates access on create)', () => {
    create();
    const kb = Object.values(Template.fromStack(stack).findResources('AWS::Bedrock::KnowledgeBase'))[0] as any;
    expect(kb.DependsOn.some((d: string) => d.includes('RoleDefaultPolicy'))).toBe(true);
  });

  describe('service role', () => {
    const statements = () => {
      const policy = Object.values(Template.fromStack(stack).findResources('AWS::IAM::Policy'))[0] as any;
      return policy.Properties.PolicyDocument.Statement as any[];
    };
    const find = (action: string) => statements().find(s => [].concat(s.Action).includes(action as never));

    test('is assumed by bedrock.amazonaws.com for knowledge bases of this account only', () => {
      create();
      Template.fromStack(stack).hasResourceProperties('AWS::IAM::Role', {
        AssumeRolePolicyDocument: {
          Statement: [Match.objectLike({
            Principal: { Service: 'bedrock.amazonaws.com' },
            Condition: {
              StringEquals: { 'aws:SourceAccount': Match.anyValue() },
              ArnLike: { 'aws:SourceArn': Match.anyValue() },
            },
          })],
        },
      });
    });

    test('lists and reads only its own document prefix', () => {
      create('nzdf');
      expect(find('s3:ListBucket').Condition).toEqual({ StringLike: { 's3:prefix': ['bedrock-kb/nzdf/*'] } });
      expect(JSON.stringify(find('s3:GetObject').Resource)).toContain('bedrock-kb/nzdf/*');
    });

    test('decrypts with the source bucket key and nothing more', () => {
      create();
      expect(find('kms:Decrypt').Resource).toBe('arn:aws:kms:ap-southeast-2:123456789012:key/12345678-1234-1234-1234-123456789012');
      expect(find('kms:GenerateDataKey')).toBeUndefined();
    });

    test('has S3 Vectors access on its own index only', () => {
      create();
      const s = find('s3vectors:QueryVectors');
      expect(s.Action).toEqual(expect.arrayContaining(['s3vectors:GetIndex', 's3vectors:PutVectors', 's3vectors:GetVectors', 's3vectors:DeleteVectors']));
      expect(s.Resource['Fn::GetAtt'][0]).toContain('VectorIndex');
      expect(s.Resource['Fn::GetAtt'][1]).toBe('IndexArn');
    });

    test('can invoke only the embedding model', () => {
      create();
      expect(JSON.stringify(find('bedrock:InvokeModel').Resource)).toContain('foundation-model/amazon.titan-embed-text-v2:0');
    });
  });

  describe('removal policy', () => {
    test('DESTROY deletes the vectors with the stack', () => {
      create();
      const template = Template.fromStack(stack);
      template.hasResourceProperties('AWS::Bedrock::DataSource', { DataDeletionPolicy: 'DELETE' });
      for (const type of ['AWS::S3Vectors::VectorBucket', 'AWS::S3Vectors::Index', 'AWS::Bedrock::KnowledgeBase', 'AWS::Bedrock::DataSource']) {
        template.hasResource(type, { DeletionPolicy: 'Delete' });
      }
    });

    test('RETAIN keeps the vector store, the knowledge base and its vectors', () => {
      create('nema-cdem', RemovalPolicy.RETAIN);
      const template = Template.fromStack(stack);
      template.hasResourceProperties('AWS::Bedrock::DataSource', { DataDeletionPolicy: 'RETAIN' });
      for (const type of ['AWS::S3Vectors::VectorBucket', 'AWS::S3Vectors::Index', 'AWS::IAM::Role', 'AWS::Bedrock::KnowledgeBase', 'AWS::Bedrock::DataSource']) {
        template.hasResource(type, { DeletionPolicy: 'Retain' });
      }
    });
  });

  test('two knowledge bases get separate vector buckets, indexes and roles', () => {
    create('nema-cdem');
    create('nzdf');
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::S3Vectors::VectorBucket', 2);
    template.resourceCountIs('AWS::S3Vectors::Index', 2);
    template.resourceCountIs('AWS::Bedrock::KnowledgeBase', 2);
    template.resourceCountIs('AWS::IAM::Role', 2);
  });

  test.each(['NEMA', 'ab', '-abc', 'abc-', 'has_underscore', 'has space', 'a'.repeat(64)])(
    'rejects the invalid name %p',
    (name) => {
      expect(() => create(name)).toThrow(/Invalid Bedrock knowledge base name/);
    }
  );
});
