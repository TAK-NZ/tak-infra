import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
export interface TakInfraStackProps extends cdk.StackProps {
    config: any;
    defaults: any;
}
export declare class TakInfraStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props: TakInfraStackProps);
}
