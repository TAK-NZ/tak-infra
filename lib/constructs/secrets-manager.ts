/**
 * Secrets Manager Construct - TAK Server secrets configuration
 */
import { Construct } from 'constructs';
import {
  aws_secretsmanager as secretsmanager,
  aws_kms as kms,
  Stack,
  RemovalPolicy
} from 'aws-cdk-lib';
import type { ContextEnvironmentConfig } from '../stack-config';

/**
 * Properties for the Secrets Manager construct
 */
export interface SecretsManagerProps {
  /**
   * Environment type ('prod' | 'dev-test')
   */
  environment: 'prod' | 'dev-test';

  /**
   * Context-based environment configuration (direct from cdk.json)
   */
  contextConfig: ContextEnvironmentConfig;

  /**
   * KMS key for secrets encryption
   */
  kmsKey: kms.IKey;
}

/**
 * CDK construct for TAK Server secrets management
 */
export class TakSecretsManager extends Construct {
  /**
   * TAK admin certificate (p12) secret
   */
  public readonly adminCertificate: secretsmanager.Secret;

  constructor(scope: Construct, id: string, props: SecretsManagerProps) {
    super(scope, id);

    const stackName = Stack.of(this).stackName;
    const removalPolicy = props.contextConfig.general.removalPolicy === 'RETAIN' ? 
      RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;

    // Create TAK admin certificate secret (following migration guide pattern)
    this.adminCertificate = new secretsmanager.Secret(this, 'AdminCertificate', {
      secretName: `${stackName}/TAK-Server/Admin-Cert`,
      description: `${stackName} TAK Server Admin key (p12)`,
      encryptionKey: props.kmsKey,
      removalPolicy: removalPolicy
    });
  }
}