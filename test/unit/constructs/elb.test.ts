/**
 * Test suite for ELB construct
 */
import { App, Stack } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Template } from 'aws-cdk-lib/assertions';
import { Elb } from '../../../lib/constructs/elb';
import { CDKTestHelper } from '../../__helpers__/cdk-test-utils';
import { MOCK_CONFIGS } from '../../__fixtures__/mock-configs';

describe('ELB Construct', () => {
  let app: App;
  let stack: Stack;
  let infrastructureConfig: any;
  let nlbSecurityGroup: ec2.SecurityGroup;

  beforeEach(() => {
    ({ app, stack } = CDKTestHelper.createTestStack());
    infrastructureConfig = CDKTestHelper.createMockInfrastructure(stack);
    nlbSecurityGroup = new ec2.SecurityGroup(stack, 'NlbSecurityGroup', {
      vpc: infrastructureConfig.vpc
    });
  });

  test('should create Network Load Balancer', () => {
    const networkConfig = CDKTestHelper.createMockNetwork();
    const elb = new Elb(stack, 'TestELB', {
      environment: 'dev-test',
      contextConfig: MOCK_CONFIGS.DEV_TEST,
      infrastructure: infrastructureConfig,
      network: networkConfig,
      nlbSecurityGroup
    });

    expect(elb.loadBalancer).toBeDefined();
    expect(elb.targetGroups).toBeDefined();
    expect(Object.keys(elb.targetGroups)).toHaveLength(5);

    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::ElasticLoadBalancingV2::LoadBalancer', {
      Type: 'network',
      IpAddressType: 'dualstack',
      Scheme: 'internet-facing'
    });
  });

  test('should create target groups', () => {
    const networkConfig = CDKTestHelper.createMockNetwork();
    const elb = new Elb(stack, 'TestELB', {
      environment: 'dev-test',
      contextConfig: MOCK_CONFIGS.DEV_TEST,
      infrastructure: infrastructureConfig,
      network: networkConfig,
      nlbSecurityGroup
    });

    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::ElasticLoadBalancingV2::TargetGroup', 5);
  });

  test('should create listeners', () => {
    const networkConfig = CDKTestHelper.createMockNetwork();
    const elb = new Elb(stack, 'TestELB', {
      environment: 'dev-test',
      contextConfig: MOCK_CONFIGS.DEV_TEST,
      infrastructure: infrastructureConfig,
      network: networkConfig,
      nlbSecurityGroup
    });

    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::ElasticLoadBalancingV2::Listener', 6);
  });
});