/**
 * Test suite for the CertificateAlarms construct (CloudWatch alarms and SNS topics, issue #129)
 */
import { Stack } from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { CERTIFICATE_ALARMS, CERTIFICATE_METRIC_NAMESPACE, CertificateAlarms, CertificateAlarmsProps } from '../../../lib/constructs/certificate-alarms';
import { CDKTestHelper } from '../../__helpers__/cdk-test-utils';

describe('CertificateAlarms construct', () => {
  let stack: Stack;
  const create = (props: Partial<CertificateAlarmsProps> = {}) =>
    new CertificateAlarms(stack, 'Alarms', { environmentLabel: 'Try', stackName: 'TAK-Try-TakInfra', ...props });

  beforeEach(() => {
    ({ stack } = CDKTestHelper.createTestStack());
  });

  test('creates one alarm per entry of the table in #129 (the rotation phase alarm once per phase)', () => {
    create();
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::CloudWatch::Alarm', CERTIFICATE_ALARMS.length);
    expect(CERTIFICATE_ALARMS.length).toBe(13);
    const names = CERTIFICATE_ALARMS.map(a => a.metric);
    for (const m of ['CertbotRenewalFailure', 'TakServerCertRotated', 'TakServerCertRotationFailed', 'AdminCertRotated', 'SigningCARotated',
      'IntermediateCAExpiryWarning', 'IntermediateCARotationPhase', 'RootCAExpiryWarning', 'RootCARotated', 'RotationCoverageStragglers', 'CAExpired']) {
      expect(names).toContain(m);
    }
    expect(names.filter(m => m === 'IntermediateCARotationPhase')).toHaveLength(3);
  });

  test('every alarm watches the namespace and the Stack dimension, fires at 1 and treats missing data as fine', () => {
    create();
    const template = Template.fromStack(stack);
    template.allResourcesProperties('AWS::CloudWatch::Alarm', {
      Namespace: CERTIFICATE_METRIC_NAMESPACE,
      Threshold: 1,
      ComparisonOperator: 'GreaterThanOrEqualToThreshold',
      EvaluationPeriods: 1,
      DatapointsToAlarm: 1,
      TreatMissingData: 'notBreaching',
      Dimensions: Match.arrayWith([{ Name: 'Stack', Value: 'TAK-Try-TakInfra' }]),
    });
  });

  test('the rotation phase alarms carry the Phase dimension', () => {
    create();
    const template = Template.fromStack(stack);
    for (const phase of ['bridge', 'cut', 'retire']) {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        MetricName: 'IntermediateCARotationPhase',
        Dimensions: [{ Name: 'Phase', Value: phase }, { Name: 'Stack', Value: 'TAK-Try-TakInfra' }],
      });
    }
  });

  test('event metrics use a 5 minute Sum, the daily checks a 1 day Maximum', () => {
    create();
    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::CloudWatch::Alarm', { MetricName: 'TakServerCertRotationFailed', Statistic: 'Sum', Period: 300 });
    for (const m of ['RootCAExpiryWarning', 'IntermediateCAExpiryWarning', 'CAExpired']) {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', { MetricName: m, Statistic: 'Maximum', Period: 86400 });
    }
  });

  test('alarm names are prefixed with the stack name and say what they are', () => {
    create();
    const template = Template.fromStack(stack);
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'TAK-Try-TakInfra-RootCAExpiryWarning',
      AlarmDescription: Match.stringLikeRegexp('^\\[ALERT\\] TAK\\.NZ Try'),
    });
    template.hasResourceProperties('AWS::CloudWatch::Alarm', { AlarmName: 'TAK-Try-TakInfra-IntermediateCARotationPhase-Bridge' });
  });

  test('three topics by severity; each alarm publishes to the topic of its severity', () => {
    const alarms = create();
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::SNS::Topic', 3);
    const byName = Object.fromEntries(
      Object.values(template.findResources('AWS::CloudWatch::Alarm')).map((a: any) => [a.Properties.AlarmName, a.Properties.AlarmActions[0]])
    );
    const ref = (t: any) => stack.resolve(t.topicArn);
    expect(byName['TAK-Try-TakInfra-CAExpired']).toEqual(ref(alarms.criticalTopic));
    expect(byName['TAK-Try-TakInfra-RootCAExpiryWarning']).toEqual(ref(alarms.alertTopic));
    expect(byName['TAK-Try-TakInfra-CertbotRenewalFailure']).toEqual(ref(alarms.alertTopic));
    expect(byName['TAK-Try-TakInfra-RotationCoverageStragglers']).toEqual(ref(alarms.alertTopic));
    expect(byName['TAK-Try-TakInfra-RootCARotated']).toEqual(ref(alarms.infoTopic));
    expect(byName['TAK-Try-TakInfra-IntermediateCARotationPhase-Cut']).toEqual(ref(alarms.infoTopic));
  });

  test('alarms act only on ALARM, not on OK', () => {
    create();
    const alarms = Object.values(Template.fromStack(stack).findResources('AWS::CloudWatch::Alarm')) as any[];
    for (const a of alarms) {
      expect(a.Properties.AlarmActions).toHaveLength(1);
      expect(a.Properties.OKActions).toBeUndefined();
    }
  });

  test('topics enforce SSL', () => {
    create();
    Template.fromStack(stack).resourceCountIs('AWS::SNS::TopicPolicy', 3);
  });

  test('no email subscription unless an address is given', () => {
    create();
    Template.fromStack(stack).resourceCountIs('AWS::SNS::Subscription', 0);
  });

  test('alertEmail subscribes the alert and critical topics, infoEmail the info topic', () => {
    create({ alertEmail: 'pki-alerts@example.org', infoEmail: 'pki-info@example.org' });
    const template = Template.fromStack(stack);
    template.resourceCountIs('AWS::SNS::Subscription', 3);
    template.resourceCountIs('AWS::SNS::Subscription', 3);
    const subs = Object.values(template.findResources('AWS::SNS::Subscription')) as any[];
    expect(subs.filter(s => s.Properties.Endpoint === 'pki-alerts@example.org')).toHaveLength(2);
    expect(subs.filter(s => s.Properties.Endpoint === 'pki-info@example.org')).toHaveLength(1);
  });
});
