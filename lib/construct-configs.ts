import {
  aws_ec2 as ec2,
  aws_ecs as ecs,
  aws_secretsmanager as secretsmanager,
  aws_s3 as s3,
  aws_kms as kms,
  aws_elasticloadbalancingv2 as elbv2,
} from 'aws-cdk-lib';

/**
 * Infrastructure configuration shared across constructs
 */
export interface InfrastructureConfig {
  /**
   * VPC for deployment
   */
  vpc: ec2.IVpc;

  /**
   * Security group for ECS tasks
   */
  ecsSecurityGroup: ec2.SecurityGroup;

  /**
   * ECS cluster
   */
  ecsCluster: ecs.ICluster;

  /**
   * KMS key for secrets encryption
   */
  kmsKey: kms.IKey;
}

/**
 * Secrets configuration for TAK Server
 */
export interface SecretsConfig {
  /**
   * Database secret
   */
  database: secretsmanager.ISecret;

  /**
   * TAK Server-specific secrets
   */
  takserver: {
    /**
     * LDAP service account credentials
     */
    ldapServiceAccount?: secretsmanager.ISecret;

    /**
     * OAuth configuration secrets
     */
    oauthConfig?: secretsmanager.ISecret;

    /**
     * TAK admin certificate (p12) secret
     */
    adminCertificate?: secretsmanager.ISecret;
    
    /**
     * Federate Certificate Authority (PEM) secret
     */
    federateCACertificate?: secretsmanager.ISecret;
  };
}

/**
 * Storage configuration for S3 and EFS
 */
export interface StorageConfig {
  /**
   * S3 configuration
   */
  s3: {
    /**
     * S3 configuration bucket for environment files
     */
    configBucket: s3.IBucket;

    /**
     * S3 URI for the environment file (optional)
     */
    envFileUri?: string;

    /**
     * S3 key for the environment file (optional)
     */
    envFileKey?: string;
  };

  /**
   * EFS configuration
   */
  efs: {
    /**
     * EFS file system ID
     */
    fileSystemId: string;

    /**
     * EFS TAK certs access point ID
     */
    takCertsAccessPointId: string;

    /**
     * EFS Let's Encrypt access point ID
     */
    letsEncryptAccessPointId: string;
    
    /**
     * EFS TAK config access point ID
     */
    takConfigAccessPointId: string;
  };
}

/**
 * Deployment configuration
 */
export interface DeploymentConfig {
  /**
   * Allow SSH exec into container
   */
  enableExecute: boolean;

  /**
   * Use TAK Server config file from S3
   */
  useConfigFile: boolean;
}

/**
 * Application configuration for TAK Server
 */
export interface TakServerApplicationConfig {
  /**
   * TAK Server hostname
   */
  hostname: string;

  /**
   * TAK Server branding
   */
  branding: string;

  /**
   * TAK Server version
   */
  version: string;

  /**
   * Database configuration
   */
  database: {
    /**
     * Database hostname
     */
    hostname: string;
  };

  /**
   * LDAP configuration
   */
  ldap?: {
    /**
     * LDAP server hostname
     */
    hostname: string;

    /**
     * LDAP base DN
     */
    baseDn: string;
  };

  /**
   * OAuth/OIDC configuration
   */
  oauth?: {
    /**
     * OAuth issuer URL
     */
    issuerUrl: string;
  };
}

/**
 * Network configuration for DNS and load balancers
 */
export interface NetworkConfig {
  /**
   * Hosted Zone ID imported from base infrastructure
   */
  hostedZoneId: string;

  /**
   * Hosted Zone Name imported from base infrastructure
   */
  hostedZoneName: string;

  /**
   * SSL certificate ARN for HTTPS
   */
  sslCertificateArn: string;

  /**
   * Hostname for TAK Server
   */
  hostname: string;

  /**
   * Load balancer (when applicable)
   */
  loadBalancer?: elbv2.ILoadBalancerV2;
}