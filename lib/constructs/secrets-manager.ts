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

  /**
   * Federate Certificate Authority (PEM) secret
   */
  public readonly federateCACertificate: secretsmanager.Secret;

  /**
   * WebTAK OIDC client secret (optional)
   */
  public readonly webTakOidcClientSecret?: secretsmanager.Secret;

  constructor(scope: Construct, id: string, props: SecretsManagerProps) {
    super(scope, id);

    const stackName = Stack.of(this).stackName;
    const removalPolicy = props.contextConfig.general.removalPolicy === 'RETAIN' ? 
      RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;

    // Create TAK admin certificate secret (following migration guide pattern)
    this.adminCertificate = new secretsmanager.Secret(this, 'AdminCertificate', {
      secretName: `${stackName}/TAK-Server/Admin-Cert`,
      description: `TAK Server Admin key (p12)`,
      encryptionKey: props.kmsKey,
      removalPolicy: removalPolicy
    });
    
    // Create Federate CA certificate secret (PEM format)
    this.federateCACertificate = new secretsmanager.Secret(this, 'FederateCACertificate', {
      secretName: `${stackName}/TAK-Server/FederateCA`,
      description: `Federate Certificate Authority (pem)`,
      encryptionKey: props.kmsKey,
      removalPolicy: removalPolicy
    });

    // Create WebTAK OIDC client secret if OIDC is enabled
    if (props.contextConfig.webtak?.enableOidc) {
      this.webTakOidcClientSecret = new secretsmanager.Secret(this, 'WebTakOidcClientSecret', {
        secretName: `${stackName}/TAK-Server/WebTAK-OIDC-Client-Secret`,
        description: `WebTAK OIDC Client Secret`,
        encryptionKey: props.kmsKey,
        removalPolicy: removalPolicy
      });
    }
  }
}