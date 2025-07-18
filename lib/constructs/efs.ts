/**
 * EFS Construct - CDK implementation of the Elastic File System for TAK Server
 */
import { Construct } from 'constructs';
import {
  aws_efs as efs,
  aws_ec2 as ec2,
  aws_kms as kms,
  aws_iam as iam,
  RemovalPolicy
} from 'aws-cdk-lib';
import type { ContextEnvironmentConfig } from '../stack-config';
import type { InfrastructureConfig } from '../construct-configs';
import { EFS_CONSTANTS } from '../utils/constants';

/**
 * Properties for the EFS construct
 */
export interface EfsProps {
  /**
   * Environment type ('prod' | 'dev-test')
   */
  environment: 'prod' | 'dev-test';

  /**
   * Context-based environment configuration (direct from cdk.json)
   */
  contextConfig: ContextEnvironmentConfig;

  /**
   * Infrastructure configuration (VPC, KMS)
   */
  infrastructure: InfrastructureConfig;

  /**
   * Security group for EFS access
   */
  efsSecurityGroup: ec2.SecurityGroup;
}

/**
 * CDK construct for the EFS file system for TAK Server
 */
export class Efs extends Construct {
  /**
   * The EFS file system
   */
  public readonly fileSystem: efs.FileSystem;

  /**
   * The EFS access point for TAK certificates
   */
  public readonly takCertsAccessPoint: efs.AccessPoint;

  /**
   * The EFS access point for Let's Encrypt certificates
   */
  public readonly letsEncryptAccessPoint: efs.AccessPoint;

  /**
   * The EFS access point for TAK configuration files
   */
  public readonly takConfigAccessPoint: efs.AccessPoint;

  constructor(scope: Construct, id: string, props: EfsProps) {
    super(scope, id);

    // Derive environment-specific values from context (matches reference pattern)
    const isHighAvailability = props.environment === 'prod';
    const efsRemovalPolicy = props.contextConfig.general.removalPolicy === 'RETAIN' ? 
      RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;
    const throughputMode = efs.ThroughputMode.BURSTING; // Use bursting mode for cost optimization

    // Use provided EFS security group
    const efsSecurityGroup = props.efsSecurityGroup;

    // Build EFS configuration object with file system policy
    const efsConfig: any = {
      vpc: props.infrastructure.vpc,
      encrypted: true,
      kmsKey: props.infrastructure.kmsKey,
      performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
      throughputMode: throughputMode,
      securityGroup: efsSecurityGroup,
      removalPolicy: efsRemovalPolicy,
      fileSystemPolicy: iam.PolicyDocument.fromJson({
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Principal: {
              AWS: '*'
            },
            Action: [
              'elasticfilesystem:ClientMount',
              'elasticfilesystem:ClientWrite',
              'elasticfilesystem:ClientRootAccess'
            ],
            Condition: {
              Bool: {
                'elasticfilesystem:AccessedViaMountTarget': 'true'
              }
            }
          }
        ]
      })
    };

    // Create the EFS file system
    this.fileSystem = new efs.FileSystem(this, 'EFS', efsConfig);

    // Create access point for TAK certificates
    this.takCertsAccessPoint = new efs.AccessPoint(this, 'EFSAccessPointTakCerts', {
      fileSystem: this.fileSystem,
      posixUser: {
        uid: '0',
        gid: '0'
      },
      path: '/opt/tak/certs/files',
      createAcl: {
        ownerUid: '0',
        ownerGid: '0',
        permissions: '0777'
      }
    });

    // Create access point for Let's Encrypt certificates
    this.letsEncryptAccessPoint = new efs.AccessPoint(this, 'EFSAccessPointLetsEncrypt', {
      fileSystem: this.fileSystem,
      posixUser: {
        uid: '0',
        gid: '0'
      },
      path: '/etc/letsencrypt',
      createAcl: {
        ownerUid: '0',
        ownerGid: '0',
        permissions: '0777'
      }
    });
    
    // Create access point for TAK configuration files
    this.takConfigAccessPoint = new efs.AccessPoint(this, 'EFSAccessPointTakConfig', {
      fileSystem: this.fileSystem,
      posixUser: {
        uid: '0',
        gid: '0'
      },
      path: '/opt/tak/persistent-config',
      createAcl: {
        ownerUid: '0',
        ownerGid: '0',
        permissions: '0777'
      }
    });
  }
}