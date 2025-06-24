import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { RemovalPolicy, StackProps, Fn, CfnOutput } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as s3 from 'aws-cdk-lib/aws-s3';

// Construct imports
// TODO: Import constructs in Phase 2

// Utility imports
import { createBaseImportValue, BASE_EXPORT_NAMES } from './cloudformation-imports';
import { ContextEnvironmentConfig } from './stack-config';
import { validateEnvType, validateStackName } from './utils';

export interface TakInfraStackProps extends StackProps {
  environment: 'prod' | 'dev-test';
  envConfig: ContextEnvironmentConfig; // Environment configuration from context
}

/**
 * Main CDK stack for the TAK Server Infrastructure
 */
export class TakInfraStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: TakInfraStackProps) {
    super(scope, id, {
      ...props,
      description: 'TAK Server Infrastructure - Database, EFS, Load Balancer, ECS Service',
    });

    // Validate configuration early
    validateEnvType(props.environment);
    validateStackName(props.envConfig.stackName);

    // Use environment configuration directly (no complex transformations needed)
    const { envConfig } = props;
    
    // Extract configuration values directly from envConfig
    const stackNameComponent = envConfig.stackName; // This is the STACK_NAME part (e.g., "Dev")
    
    const isHighAvailability = props.environment === 'prod';
    const environmentLabel = props.environment === 'prod' ? 'Prod' : 'Dev-Test';
    const resolvedStackName = id;
    
    // Use computed values from configuration
    const enableHighAvailability = isHighAvailability;
    const enableDetailedLogging = envConfig.general.enableDetailedLogging;

    // Get runtime CloudFormation values for stack outputs and resource naming
    const stackName = Fn.ref('AWS::StackName');
    const region = cdk.Stack.of(this).region;

    // Configuration-based parameter resolution
    const takServerHostname = envConfig.takserver.hostname;
    const takServerBranding = envConfig.takserver.branding;
    const takServerVersion = envConfig.takserver.version;
    const useS3ConfigFile = envConfig.takserver.useS3Config;
    const enableEcsExec = envConfig.ecs.enableEcsExec ?? false;

    // =================
    // IMPORT BASE INFRASTRUCTURE RESOURCES
    // =================

    // TODO: Import VPC, ECS cluster, KMS, S3, Route53, ACM certificate in Phase 2
    
    // =================
    // CORE INFRASTRUCTURE
    // =================

    // TODO: Implement TAK infrastructure constructs in Phase 2
    // - Database (PostgreSQL Aurora)
    // - EFS (File System + Access Points)
    // - Load Balancer (NLB + Target Groups)
    // - Security Groups
    // - ECS Service (Task Definition + Service)
    // - Route53 (DNS Records)
    
    // =================
    // STACK OUTPUTS
    // =================

    // TODO: Register stack outputs in Phase 2
  }
}