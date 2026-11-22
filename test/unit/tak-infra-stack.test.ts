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

  describe('Root CA and Intermediate CA keys in KMS (#136)', () => {
    const build = (pki?: any) => {
      const stack = new TakInfraStack(new App(), 'TAK-Try-TakInfra', {
        environment: 'dev-test',
        envConfig: { ...MOCK_CONFIGS.DEV_TEST, pki },
        env: { account: '123456789012', region: 'ap-southeast-2' }
      });
      return Template.fromStack(stack);
    };
    const kmsKeysWithSigningPolicy = (template: Template) =>
      Object.values(template.findResources('AWS::KMS::Key')).filter(
        (r: any) => r.Properties.KeySpec === 'RSA_4096'
      );

    test('creates nothing and sets no container variables by default', () => {
      const template = build();
      expect(kmsKeysWithSigningPolicy(template)).toHaveLength(0);
      const defs = Object.values(template.findResources('AWS::ECS::TaskDefinition')) as any[];
      const env = JSON.stringify(defs[0].Properties.ContainerDefinitions[0].Environment);
      expect(env).not.toContain('PKI_KMS_CA_KEYS');
    });

    test('creates nothing when disabled', () => {
      expect(kmsKeysWithSigningPolicy(build({ kmsCa: { enabled: false, environmentLabel: 'Try' } }))).toHaveLength(0);
    });

    test('creates the keys and passes them to the container when enabled', () => {
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try' } });
      expect(kmsKeysWithSigningPolicy(template)).toHaveLength(4); // generation 1 and the spare generation 2 of both tiers
      template.hasResourceProperties('AWS::KMS::Alias', { AliasName: 'alias/tak-nz-try-root-ca-01' });
      const defs = Object.values(template.findResources('AWS::ECS::TaskDefinition')) as any[];
      const env = defs[0].Properties.ContainerDefinitions[0].Environment as any[];
      const byName = Object.fromEntries(env.map(e => [e.Name, e.Value]));
      expect(byName.PKI_ENV_LABEL).toBe('Try');
      expect(byName.PKI_KMS_REGION).toBe('ap-southeast-2');
      const slots = JSON.stringify(byName.PKI_KMS_CA_KEYS);
      expect(slots).toContain('root-ca-01=');
      expect(slots).toContain('intermediate-ca-01=');
      expect(slots).toContain('root-ca-02=');
      expect(slots).toContain('intermediate-ca-02=');
    });

    test('creates the certificate alarms and sends the Root CA signing alert to their alert topic', () => {
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try' } });
      template.resourceCountIs('AWS::CloudWatch::Alarm', 19);
      template.resourceCountIs('AWS::SNS::Topic', 3);
      template.hasResourceProperties('AWS::CloudWatch::Alarm', { Namespace: 'TAK/Certificates', MetricName: 'RootCAExpiryWarning',
        Dimensions: [{ Name: 'Stack', Value: 'TAK-Try-TakInfra' }] });
      const rule = Object.values(template.findResources('AWS::Events::Rule'))[0] as any;
      const target = JSON.stringify(rule.Properties.Targets[0].Arn);
      expect(target).toContain('AlertTopic');
    });

    test('creates no alarms when the PKI keys are off', () => {
      const template = build();
      template.resourceCountIs('AWS::CloudWatch::Alarm', 0);
    });

    test('passes the first-boot PKI settings to the container', () => {
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try' } });
      const defs = Object.values(template.findResources('AWS::ECS::TaskDefinition')) as any[];
      const env = defs[0].Properties.ContainerDefinitions[0].Environment as any[];
      const byName = Object.fromEntries(env.map(e => [e.Name, e.Value]));
      expect(byName.P12_PROFILE).toBe('compat3des');
      expect(byName.PKI_ROOT_DAYS).toBe('7300');
      expect(byName.PKI_INTERMEDIATE_DAYS).toBe('3650');
      expect(byName.PKI_ENROLLMENT_CA_DAYS).toBe('1095');
      expect(byName.PKI_SERVER_CERT_DAYS).toBe('365');
      expect(byName.PKI_ADMIN_CERT_DAYS).toBe('365');
      expect(byName.PKI_SERVER_CERT_RENEW_DAYS).toBe('60');
      expect(byName.PKI_ADMIN_CERT_RENEW_DAYS).toBe('60');
      expect(byName.PKI_ADMIN_CERT_GRACE_DAYS).toBe('7');
      expect(JSON.stringify(byName.PKI_ALERT_TOPIC_ARN)).toContain('AlertTopic');
      expect(byName.PKI_CLIENT_CERT_DAYS).toBe('365');
      expect(byName.PKI_ROTATION_BUFFER_DAYS).toBe('90');
      expect(byName.PKI_ENROLLMENT_CA_ROTATION_DAYS).toBe('365');
      expect(byName.PKI_ROTATION_REQUIRE_APPROVAL).toBe('cut,retire');
      // the Enrollment CA secret (Ref to the secret)
      expect(JSON.stringify(byName.PKI_ENROLLMENT_CA_SECRET)).toContain('EnrollmentCaSecret');
      // CN first: service name, then host name, both under the hosted zone from BaseInfra (never literal)
      const names = JSON.stringify(byName.PKI_SERVER_NAMES);
      expect(names).toContain(`${MOCK_CONFIGS.DEV_TEST.takserver.servicename}.`);
      expect(names).toContain(`${MOCK_CONFIGS.DEV_TEST.takserver.hostname}.`);
      expect(names.indexOf(`${MOCK_CONFIGS.DEV_TEST.takserver.servicename}.`)).toBeLessThan(names.indexOf(`${MOCK_CONFIGS.DEV_TEST.takserver.hostname}.`));
    });

    test('custom validities and the aes256 profile reach the container', () => {
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try', p12Profile: 'aes256', validity: { serverCertDays: 200 } } });
      const defs = Object.values(template.findResources('AWS::ECS::TaskDefinition')) as any[];
      const byName = Object.fromEntries((defs[0].Properties.ContainerDefinitions[0].Environment as any[]).map(e => [e.Name, e.Value]));
      expect(byName.P12_PROFILE).toBe('aes256');
      expect(byName.PKI_SERVER_CERT_DAYS).toBe('200');
      expect(byName.PKI_SERVER_CERT_RENEW_DAYS).toBe('60');
      expect(byName.PKI_ROOT_DAYS).toBe('7300');
    });

    test('a validity that outlives its issuer fails the synth', () => {
      expect(() => build({ kmsCa: { enabled: true, environmentLabel: 'Try', validity: { serverCertDays: 5000 } } })).toThrow(/must not outlive its issuer/);
    });

    test('a renewal threshold that is not smaller than the server certificate validity fails the synth', () => {
      expect(() => build({ kmsCa: { enabled: true, environmentLabel: 'Try', validity: { serverCertDays: 60 } } })).toThrow(/must be smaller than serverCertDays/);
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try', validity: { serverCertDays: 30, serverCertRenewDays: 10 } } });
      const defs = Object.values(template.findResources('AWS::ECS::TaskDefinition')) as any[];
      const byName = Object.fromEntries((defs[0].Properties.ContainerDefinitions[0].Environment as any[]).map(e => [e.Name, e.Value]));
      expect(byName.PKI_SERVER_CERT_RENEW_DAYS).toBe('10');
    });
    test('rotation settings reach the container and a setting that cannot work fails the synth', () => {
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try', rotation: { bufferDays: 30, requireApproval: ['cut', 'retire'] } } });
      const defs = Object.values(template.findResources('AWS::ECS::TaskDefinition')) as any[];
      const byName = Object.fromEntries((defs[0].Properties.ContainerDefinitions[0].Environment as any[]).map(e => [e.Name, e.Value]));
      expect(byName.PKI_ROTATION_BUFFER_DAYS).toBe('30');
      expect(byName.PKI_ROTATION_REQUIRE_APPROVAL).toBe('cut,retire');
      expect(() => build({ kmsCa: { enabled: true, environmentLabel: 'Try', rotation: { enrollmentCaRotationDays: 900 } } })).toThrow(/Enrollment CA validity/);
    });
    test('the task role may publish to the alert topic, for the list of users that the coverage check reports (#171)', () => {
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try' } });
      const policies = Object.values(template.findResources('AWS::IAM::Policy')) as any[];
      const publish = policies.flatMap(p => p.Properties.PolicyDocument.Statement as any[])
        .filter(s => ([] as string[]).concat(s.Action).includes('sns:Publish') && JSON.stringify(s.Resource).includes('AlertTopic'));
      expect(publish.length).toBeGreaterThan(0);
    });
    test('the signer in the key policy is the task role of the TAK Server task', () => {
      const template = build({ kmsCa: { enabled: true, environmentLabel: 'Try' } });
      const defs = Object.values(template.findResources('AWS::ECS::TaskDefinition')) as any[];
      const taskRoleRef = defs[0].Properties.TaskRoleArn['Fn::GetAtt'][0];
      for (const key of kmsKeysWithSigningPolicy(template) as any[]) {
        const signer = key.Properties.KeyPolicy.Statement.find((st: any) => st.Sid === 'SignerRoleCanSign');
        expect(signer.Principal.AWS['Fn::GetAtt'][0]).toBe(taskRoleRef);
      }
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