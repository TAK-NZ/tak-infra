/**
 * Test suite for the CaKmsKeys construct (Root CA and Intermediate CA keys in KMS, issue #136)
 */
import { Stack } from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { CaKmsKeys, CaKmsKeysProps } from '../../../lib/constructs/ca-kms-keys';
import { CDKTestHelper } from '../../__helpers__/cdk-test-utils';

describe('CaKmsKeys construct', () => {
  let stack: Stack;
  let role: iam.Role;

  const create = (props: Partial<CaKmsKeysProps> = {}) =>
    new CaKmsKeys(stack, 'CaKeys', { environmentLabel: 'Try', signerRole: role, ...props });

  beforeEach(() => {
    ({ stack } = CDKTestHelper.createTestStack());
    role = new iam.Role(stack, 'TaskRole', { assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com') });
  });

  test('creates one RSA-4096 sign/verify key for the root and one for the intermediate by default', () => {
    create();
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::KMS::Key', 2);
    template.allResourcesProperties('AWS::KMS::Key', {
      KeySpec: 'RSA_4096',
      KeyUsage: 'SIGN_VERIFY',
    });
  });

  test('aliases follow the naming rules', () => {
    create();
    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::KMS::Alias', { AliasName: 'alias/tak-nz-try-root-ca-01' });
    template.hasResourceProperties('AWS::KMS::Alias', { AliasName: 'alias/tak-nz-try-intermediate-ca-01' });
  });

  test('descriptions carry the CA common name', () => {
    create();
    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::KMS::Key', { Description: Match.stringLikeRegexp('TAK\\.NZ Try Root CA 01') });
    template.hasResourceProperties('AWS::KMS::Key', { Description: Match.stringLikeRegexp('TAK\\.NZ Try Intermediate CA 01') });
  });

  test('keys are never deleted by CloudFormation', () => {
    create();
    Template.fromStack(stack).allResources('AWS::KMS::Key', {
      DeletionPolicy: 'Retain',
      UpdateReplacePolicy: 'Retain',
    });
  });

  test('more generations create more keys with the next numbers', () => {
    const keys = create({ rootCaNumbers: [1, 2], intermediateCaNumbers: [1, 2, 3] });
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::KMS::Key', 5);
    template.hasResourceProperties('AWS::KMS::Alias', { AliasName: 'alias/tak-nz-try-root-ca-02' });
    template.hasResourceProperties('AWS::KMS::Alias', { AliasName: 'alias/tak-nz-try-intermediate-ca-03' });
    expect(keys.keys.map(k => k.commonName)).toContain('TAK.NZ Try Intermediate CA 03');
  });

  test('key policy: account root has no signing action, only the signer role may sign, everyone else is denied', () => {
    create();
    const template = Template.fromStack(stack);
    const keys = template.findResources('AWS::KMS::Key');
    for (const resource of Object.values(keys)) {
      const statements = (resource as any).Properties.KeyPolicy.Statement as any[];
      const byId = Object.fromEntries(statements.map(s => [s.Sid, s]));

      const management = byId.KeyManagementWithoutSigning;
      expect(management.Effect).toBe('Allow');
      expect(management.Action).not.toContain('kms:Sign');
      expect(management.Action).not.toContain('kms:*');
      expect(management.Action).not.toContain('kms:Encrypt');
      expect(management.Action).toContain('kms:Put*'); // PutKeyPolicy keeps the key recoverable

      const signer = byId.SignerRoleCanSign;
      expect(signer.Effect).toBe('Allow');
      expect(signer.Action).toEqual(['kms:Sign', 'kms:GetPublicKey', 'kms:DescribeKey']);
      expect(signer.Principal.AWS).toEqual(stack.resolve(role.roleArn));

      const deny = byId.DenySigningForEveryoneElse;
      expect(deny.Effect).toBe('Deny');
      expect(deny.Principal).toEqual({ AWS: '*' });
      expect(deny.Action).toBe('kms:Sign');
      expect(deny.Condition.ArnNotEquals['aws:PrincipalArn']).toEqual(stack.resolve(role.roleArn));
    }
  });

  test('alerts on every Root CA signature, and only the Root CA keys', () => {
    create({ rootCaNumbers: [1, 2] });
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::SNS::Topic', 1);
    const rules = Object.values(template.findResources('AWS::Events::Rule'));
    expect(rules).toHaveLength(1);
    const rule = rules[0] as any;
    // Sign is a read-only management event: the default rule state would never match it
    expect(rule.Properties.State).toBe('ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS');
    expect(rule.Properties.EventPattern.source).toEqual(['aws.kms']);
    expect(rule.Properties.EventPattern.detail.eventName).toEqual(['Sign']);
    const arns = rule.Properties.EventPattern.detail.resources.ARN as any[];
    expect(arns).toHaveLength(2); // the two root keys, not the intermediate
    for (const arn of arns) {
      expect(arn['Fn::GetAtt'][0]).toMatch(/RootCa/);
    }
    template.hasResourceProperties('AWS::SNS::TopicPolicy', Match.anyValue());
  });

  test('email subscription only when an address is given', () => {
    create();
    Template.fromStack(stack).resourceCountIs('AWS::SNS::Subscription', 0);
  });

  test('subscribes the alert email address', () => {
    create({ alertEmail: 'pki-alerts@example.org' });
    Template.fromStack(stack).hasResourceProperties('AWS::SNS::Subscription', {
      Protocol: 'email',
      Endpoint: 'pki-alerts@example.org',
    });
  });

  test('pkcs11SlotsValue lists label=keyId pairs for the container', () => {
    const keys = create();
    const value = Stack.of(stack).resolve(keys.pkcs11SlotsValue);
    expect(JSON.stringify(value)).toContain('root-ca-01=');
    expect(JSON.stringify(value)).toContain('intermediate-ca-01=');
  });

  test.each([
    [{ rootCaNumbers: [] }, /at least one/],
    [{ rootCaNumbers: [1, 1] }, /duplicates/],
    [{ intermediateCaNumbers: [0] }, /CA number/],
    [{ environmentLabel: 'bad/label' }, /environment label/],
  ])('rejects invalid input %j', (props, message) => {
    expect(() => create(props as Partial<CaKmsKeysProps>)).toThrow(message);
  });
});
