/**
 * CA KMS Keys Construct - Root CA and Intermediate CA signing keys in AWS KMS (issue #136)
 *
 * Creates one asymmetric RSA-4096 KMS key per Root CA and Intermediate CA generation, so the
 * private keys never exist as files on EFS, in container memory or in Secrets Manager. TAK
 * Server's task signs through the `aws-kms-pkcs11` module (`kms:Sign`); see
 * `docker-container/scripts/kms-ca.sh`.
 *
 * Key policy (instead of relying on the account-wide IAM delegation):
 * - the account root keeps the management actions only (no `kms:Sign`), so keys stay
 *   recoverable and manageable;
 * - the signer role (the TAK Server task role) is allowed `kms:Sign`, `kms:GetPublicKey` and
 *   `kms:DescribeKey`;
 * - an explicit deny on `kms:Sign` applies to everyone else, including account administrators.
 *
 * KMS never exports the private key of an asymmetric key, so there is no export statement.
 *
 * Every use of a Root CA key raises an alert: an EventBridge rule on the CloudTrail `Sign`
 * event for the root key ARNs publishes to an SNS topic. `Sign` is a read-only management event,
 * so the rule uses state `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`, and the account needs
 * a CloudTrail trail that logs management events (read and write) in this Region.
 *
 * Keys are never deleted by CloudFormation (RETAIN). Retire a key with a 30-day deletion window
 * (`aws kms schedule-key-deletion --pending-window-in-days 30`) when its rotation is complete
 * (#169, #172).
 */
import { Construct } from 'constructs';
import {
  aws_events as events,
  aws_events_targets as targets,
  aws_iam as iam,
  aws_kms as kms,
  aws_secretsmanager as secretsmanager,
  aws_sns as sns,
  aws_sns_subscriptions as subscriptions,
  CfnOutput,
  RemovalPolicy,
  Stack,
} from 'aws-cdk-lib';
import { CaTier, caCommonName, caKeyLabel, caSlug, validateCaNumber, validateEnvironmentLabel } from '../utils/pki-names';

export interface CaKmsKeysProps {
  /** Environment label used in CA names and aliases, e.g. `Try` -> `TAK.NZ Try Root CA 01`. */
  environmentLabel: string;
  /** Role that signs with the keys (the TAK Server task role). */
  signerRole: iam.IRole;
  /**
   * Root CA generations to create keys for. Default `[1, 2]`: generation 2 is created from the start as the
   * spare for the next rotation, so that the orchestrator (#171) never waits for an operator deploy. A key costs
   * about US$1 a month and cannot be used by anyone but the signer role.
   */
  rootCaNumbers?: number[];
  /** Intermediate CA generations to create keys for. Default `[1, 2]` (see `rootCaNumbers`). */
  intermediateCaNumbers?: number[];
  /**
   * Topic that receives the alert on every Root CA signature. Default: the construct creates its own
   * topic. The TAK Server stack passes the alert topic of `CertificateAlarms` so that every alert
   * arrives in one place (#129).
   */
  alertTopic?: sns.ITopic;
  /** Email address subscribed to the topic the construct creates itself. Ignored when `alertTopic` is given. */
  alertEmail?: string;
  /** Key that encrypts the Enrollment CA secret. Default: the AWS managed key for Secrets Manager. */
  secretEncryptionKey?: kms.IKey;
}

export interface CaKmsKey {
  tier: CaTier;
  number: number;
  /** Subject CN of the CA this key belongs to, e.g. `TAK.NZ Try Root CA 01`. */
  commonName: string;
  /** PKCS#11 token label, e.g. `root-ca-01`. */
  label: string;
  key: kms.Key;
}

export class CaKmsKeys extends Construct {
  public readonly keys: CaKmsKey[];
  /** SNS topic that receives an alert on every Root CA signature. */
  public readonly rootSignAlertTopic: sns.ITopic;
  /**
   * Holds the Enrollment CA keystore (PKCS#12 with the key and the chain [Cl, S, R]). `pki-bootstrap.sh`
   * writes it on the first start and restores it into tmpfs on every later start, so the Enrollment CA
   * key never sits on the EFS (#189). Retained: it is the only copy of that key.
   */
  public readonly enrollmentCaSecret: secretsmanager.Secret;

  constructor(scope: Construct, id: string, props: CaKmsKeysProps) {
    super(scope, id);

    validateEnvironmentLabel(props.environmentLabel);
    const rootNumbers = this.uniqueNumbers(props.rootCaNumbers ?? [1, 2], 'rootCaNumbers');
    const intermediateNumbers = this.uniqueNumbers(props.intermediateCaNumbers ?? [1, 2], 'intermediateCaNumbers');

    this.keys = [
      ...rootNumbers.map(n => this.createKey(props, 'root', n)),
      ...intermediateNumbers.map(n => this.createKey(props, 'intermediate', n)),
    ];

    this.enrollmentCaSecret = new secretsmanager.Secret(this, 'EnrollmentCaSecret', {
      description: `${props.environmentLabel} Enrollment CA keystore (key and chain), written by pki-bootstrap.sh`,
      encryptionKey: props.secretEncryptionKey,
      removalPolicy: RemovalPolicy.RETAIN,
    });
    this.enrollmentCaSecret.grantRead(props.signerRole);
    this.enrollmentCaSecret.grantWrite(props.signerRole);

    // Alert on every use of a Root CA key
    if (props.alertTopic) {
      this.rootSignAlertTopic = props.alertTopic;
    } else {
      const own = new sns.Topic(this, 'RootCaSignAlertTopic', {
        displayName: `TAK.NZ ${props.environmentLabel} Root CA signing alert`,
        enforceSSL: true,
      });
      if (props.alertEmail) {
        own.addSubscription(new subscriptions.EmailSubscription(props.alertEmail));
      }
      this.rootSignAlertTopic = own;
    }

    const rootKeyArns = this.keys.filter(k => k.tier === 'root').map(k => k.key.keyArn);
    const rule = new events.Rule(this, 'RootCaSignRule', {
      description: 'Alert on every kms:Sign call that uses a Root CA key',
      eventPattern: {
        source: ['aws.kms'],
        detailType: ['AWS API Call via CloudTrail'],
        detail: {
          eventSource: ['kms.amazonaws.com'],
          eventName: ['Sign'],
          resources: { ARN: rootKeyArns },
        },
      },
      targets: [
        new targets.SnsTopic(this.rootSignAlertTopic, {
          message: events.RuleTargetInput.fromText(
            `TAK.NZ ${props.environmentLabel}: a Root CA key was used to sign. ` +
            `Caller: ${events.EventField.fromPath('$.detail.userIdentity.arn')}, ` +
            `key: ${events.EventField.fromPath('$.detail.resources[0].ARN')}, ` +
            `time: ${events.EventField.fromPath('$.detail.eventTime')}`
          ),
        }),
      ],
    });
    // Sign is a read-only management event; the default rule state does not match those.
    (rule.node.defaultChild as events.CfnRule).state = 'ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS';

    // Outputs for operators and scripts
    for (const k of this.keys) {
      const suffix = `${k.tier === 'root' ? 'RootCa' : 'IntermediateCa'}${String(k.number).padStart(2, '0')}`;
      new CfnOutput(this, `${suffix}KeyId`, {
        value: k.key.keyId,
        description: `KMS key id of ${k.commonName}`,
      });
    }
  }

  /**
   * Value for the container: `<label>=<kms key id>` pairs separated by commas, e.g.
   * `root-ca-01=1234...,intermediate-ca-01=5678...`. `kms-ca.sh` turns this into the
   * `aws-kms-pkcs11` config.
   */
  public get pkcs11SlotsValue(): string {
    return this.keys.map(k => `${k.label}=${k.key.keyId}`).join(',');
  }

  private uniqueNumbers(numbers: number[], name: string): number[] {
    if (numbers.length === 0) {
      throw new Error(`${name} must contain at least one number`);
    }
    numbers.forEach(validateCaNumber);
    if (new Set(numbers).size !== numbers.length) {
      throw new Error(`${name} contains duplicates: ${numbers.join(', ')}`);
    }
    return [...numbers].sort((a, b) => a - b);
  }

  private createKey(props: CaKmsKeysProps, tier: CaTier, n: number): CaKmsKey {
    const commonName = caCommonName(props.environmentLabel, tier, n);
    const label = caKeyLabel(tier, n);
    const slug = caSlug(props.environmentLabel, tier, n);
    const stack = Stack.of(this);

    const policy = new iam.PolicyDocument({
      statements: [
        // Account root: management only, no cryptographic operations. Keeps the key recoverable.
        new iam.PolicyStatement({
          sid: 'KeyManagementWithoutSigning',
          effect: iam.Effect.ALLOW,
          principals: [new iam.AccountRootPrincipal()],
          actions: [
            'kms:Create*', 'kms:Describe*', 'kms:Enable*', 'kms:List*', 'kms:Put*', 'kms:Update*',
            'kms:Revoke*', 'kms:Disable*', 'kms:Get*', 'kms:Delete*', 'kms:TagResource',
            'kms:UntagResource', 'kms:ScheduleKeyDeletion', 'kms:CancelKeyDeletion',
          ],
          resources: ['*'],
        }),
        new iam.PolicyStatement({
          sid: 'SignerRoleCanSign',
          effect: iam.Effect.ALLOW,
          principals: [new iam.ArnPrincipal(props.signerRole.roleArn)],
          actions: ['kms:Sign', 'kms:GetPublicKey', 'kms:DescribeKey'],
          resources: ['*'],
        }),
        // Nobody else can sign, including administrators and the account root.
        new iam.PolicyStatement({
          sid: 'DenySigningForEveryoneElse',
          effect: iam.Effect.DENY,
          principals: [new iam.AnyPrincipal()],
          actions: ['kms:Sign'],
          resources: ['*'],
          conditions: { ArnNotEquals: { 'aws:PrincipalArn': props.signerRole.roleArn } },
        }),
      ],
    });

    const key = new kms.Key(this, `${tier === 'root' ? 'RootCa' : 'IntermediateCa'}${String(n).padStart(2, '0')}`, {
      alias: slug,
      description: `${commonName} signing key (${stack.stackName})`,
      keySpec: kms.KeySpec.RSA_4096,
      keyUsage: kms.KeyUsage.SIGN_VERIFY,
      policy,
      removalPolicy: RemovalPolicy.RETAIN,
    });

    return { tier, number: n, commonName, label, key };
  }
}
