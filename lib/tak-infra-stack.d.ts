import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { StackProps } from 'aws-cdk-lib';
import { ContextEnvironmentConfig } from './stack-config';
export interface TakInfraStackProps extends StackProps {
    environment: 'prod' | 'dev-test';
    envConfig: ContextEnvironmentConfig;
}
/**
 * Main CDK stack for the TAK Server Infrastructure
 */
export declare class TakInfraStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props: TakInfraStackProps);
}
