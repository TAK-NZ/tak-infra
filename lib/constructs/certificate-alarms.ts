/**
 * Certificate Alarms Construct - CloudWatch alarms and SNS topics for the certificate rotation
 * work (issue #129, architecture in #171).
 *
 * The container emits the metrics with `cert-metrics.sh` into the namespace `TAK/Certificates`, with
 * the dimension `Stack` (this stack's name). Some metrics are emitted by tickets that are not built
 * yet (#131, #132, #135, #169, #171, #172, #130): their alarms exist from the first deploy and stay
 * in OK, because missing data does not breach.
 *
 * Three SNS topics by severity:
 * - alert: something needs a human soon (a failed rotation, a CA that is about to expire)
 * - critical: something is broken now (an expired CA)
 * - info: a rotation step happened
 * The Root CA signing alert (an EventBridge rule on the CloudTrail `Sign` event, #136) publishes to
 * the alert topic, so every "needs a human" message arrives in one place.
 */
import { Construct } from 'constructs';
import {
  Duration,
  aws_cloudwatch as cloudwatch,
  aws_cloudwatch_actions as cwActions,
  aws_sns as sns,
  aws_sns_subscriptions as subscriptions,
} from 'aws-cdk-lib';

export const CERTIFICATE_METRIC_NAMESPACE = 'TAK/Certificates';

export type AlarmSeverity = 'alert' | 'critical' | 'info';

export interface CertificateMetricAlarm {
  /** Metric name in `TAK/Certificates` */
  metric: string;
  /** Extra dimension, e.g. the rotation phase */
  dimensions?: Record<string, string>;
  severity: AlarmSeverity;
  /** Window of one datapoint: event metrics 5 minutes, daily checks 1 day */
  periodMinutes: number;
  /** `Sum` for events, `Maximum` for a check that emits 0 or 1 every day */
  statistic: 'Sum' | 'Maximum';
  description: string;
}

const EVENT = { periodMinutes: 5, statistic: 'Sum' } as const;
const DAILY = { periodMinutes: 1440, statistic: 'Maximum' } as const;

/** The alarms of #129. Thresholds follow #171 (W = 365 d + 90 d buffer). */
export const CERTIFICATE_ALARMS: readonly CertificateMetricAlarm[] = [
  { metric: 'CertbotRenewalFailure', severity: 'alert', ...EVENT, description: "Let's Encrypt renewal failed (#130)" },
  { metric: 'TakServerCertRotated', severity: 'info', ...EVENT, description: 'The TAK Server TLS certificate was rotated (#131)' },
  { metric: 'TakServerCertRotationFailed', severity: 'alert', ...EVENT, description: 'The TAK Server TLS certificate rotation failed (#131)' },
  { metric: 'AdminCertRotated', severity: 'info', ...EVENT, description: 'The admin certificate was rotated (#132)' },
  { metric: 'SigningCARotated', severity: 'info', ...EVENT, description: 'The Enrollment Signing CA was rotated (#135)' },
  { metric: 'IntermediateCAExpiryWarning', severity: 'alert', ...DAILY, description: 'The Intermediate CA is inside the window in which its rotation must start (2W + 1 year before expiry, #172)' },
  { metric: 'IntermediateCARotationPhase', dimensions: { Phase: 'bridge' }, severity: 'info', ...EVENT, description: 'Intermediate CA rotation: bridge phase started (#172)' },
  { metric: 'IntermediateCARotationPhase', dimensions: { Phase: 'cut' }, severity: 'info', ...EVENT, description: 'Intermediate CA rotation: cut phase started (#172)' },
  { metric: 'IntermediateCARotationPhase', dimensions: { Phase: 'retire' }, severity: 'info', ...EVENT, description: 'Intermediate CA rotation: retire phase started (#172)' },
  { metric: 'RootCAExpiryWarning', severity: 'alert', ...DAILY, description: 'The Root CA expires in 730 days or less (#136, #169)' },
  { metric: 'RootCARotated', severity: 'info', ...EVENT, description: 'The Root CA was rotated (#169)' },
  { metric: 'RotationCoverageStragglers', severity: 'alert', ...EVENT, description: 'Active users have not re-enrolled when a rotation gate opens (#171)' },
  { metric: 'CAExpired', severity: 'critical', ...DAILY, description: 'A CA certificate has expired' },
];

export interface CertificateAlarmsProps {
  /** Environment label, e.g. `Try`. Used in names and descriptions. */
  environmentLabel: string;
  /** Value of the `Stack` dimension: the name of the stack whose container emits the metrics. */
  stackName: string;
  /** Email address for the alert and critical topics. Optional. */
  alertEmail?: string;
  /** Email address for the info topic. Optional. */
  infoEmail?: string;
}

export class CertificateAlarms extends Construct {
  public readonly alertTopic: sns.Topic;
  public readonly criticalTopic: sns.Topic;
  public readonly infoTopic: sns.Topic;
  public readonly alarms: cloudwatch.Alarm[];

  constructor(scope: Construct, id: string, props: CertificateAlarmsProps) {
    super(scope, id);

    const topic = (name: string, severity: string): sns.Topic =>
      new sns.Topic(this, `${name}Topic`, {
        displayName: `TAK.NZ ${props.environmentLabel} certificate ${severity}`,
        enforceSSL: true,
      });
    this.alertTopic = topic('Alert', 'alert');
    this.criticalTopic = topic('Critical', 'critical');
    this.infoTopic = topic('Info', 'info');
    if (props.alertEmail) {
      this.alertTopic.addSubscription(new subscriptions.EmailSubscription(props.alertEmail));
      this.criticalTopic.addSubscription(new subscriptions.EmailSubscription(props.alertEmail));
    }
    if (props.infoEmail) {
      this.infoTopic.addSubscription(new subscriptions.EmailSubscription(props.infoEmail));
    }

    const topics: Record<AlarmSeverity, sns.Topic> = {
      alert: this.alertTopic,
      critical: this.criticalTopic,
      info: this.infoTopic,
    };

    this.alarms = CERTIFICATE_ALARMS.map(def => {
      const suffix = def.dimensions ? Object.values(def.dimensions).map(v => v[0].toUpperCase() + v.slice(1)).join('') : '';
      const alarm = new cloudwatch.Alarm(this, `${def.metric}${suffix}Alarm`, {
        alarmName: `${props.stackName}-${def.metric}${suffix ? `-${suffix}` : ''}`,
        alarmDescription: `[${def.severity.toUpperCase()}] TAK.NZ ${props.environmentLabel}: ${def.description}`,
        metric: new cloudwatch.Metric({
          namespace: CERTIFICATE_METRIC_NAMESPACE,
          metricName: def.metric,
          dimensionsMap: { Stack: props.stackName, ...def.dimensions },
          statistic: def.statistic,
          period: Duration.minutes(def.periodMinutes),
        }),
        threshold: 1,
        evaluationPeriods: 1,
        datapointsToAlarm: 1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        // A metric that was never emitted (its ticket is not built yet) or not emitted in this period is fine
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });
      alarm.addAlarmAction(new cwActions.SnsAction(topics[def.severity]));
      return alarm;
    });
  }
}
