/**
 * Test suite for EFS construct
 */
import { App, Stack } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Template } from 'aws-cdk-lib/assertions';
import { Efs } from '../../../lib/constructs/efs';
import { CDKTestHelper } from '../../__helpers__/cdk-test-utils';
import { MOCK_CONFIGS } from '../../__fixtures__/mock-configs';

describe('EFS Construct', () => {
  let app: App;
  let stack: Stack;
  let infrastructureConfig: any;
  let efsSecurityGroup: ec2.SecurityGroup;

  beforeEach(() => {
    ({ app, stack } = CDKTestHelper.createTestStack());
    infrastructureConfig = CDKTestHelper.createMockInfrastructure(stack);
    efsSecurityGroup = new ec2.SecurityGroup(stack, 'EfsSecurityGroup', {
      vpc: infrastructureConfig.vpc
    });
  });

  test('should create EFS file system with encryption', () => {
    const efs = new Efs(stack, 'TestEFS', {
      environment: 'dev-test',
      contextConfig: MOCK_CONFIGS.DEV_TEST,
      infrastructure: infrastructureConfig,
      efsSecurityGroup
    });

    expect(efs.fileSystem).toBeDefined();
    expect(efs.takCertsAccessPoint).toBeDefined();
    expect(efs.letsEncryptAccessPoint).toBeDefined();

    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::EFS::FileSystem', {
      Encrypted: true,
      PerformanceMode: 'generalPurpose',
      ThroughputMode: 'bursting'
    });
  });

  test('should create access points', () => {
    const efs = new Efs(stack, 'TestEFS', {
      environment: 'dev-test',
      contextConfig: MOCK_CONFIGS.DEV_TEST,
      infrastructure: infrastructureConfig,
      efsSecurityGroup
    });

    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::EFS::AccessPoint', 2);
  });
});