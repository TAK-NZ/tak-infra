/**
 * Centralized outputs management for the TAK Infrastructure stack
 */
import * as cdk from 'aws-cdk-lib';
export interface OutputParams {
    stack: cdk.Stack;
    stackName: string;
    databaseEndpoint: string;
    databaseSecretArn: string;
    efsId: string;
    efsTakCertsAccessPointId: string;
    efsLetsEncryptAccessPointId: string;
    takServerNlbDns: string;
    takServerUrl: string;
    takServerApiUrl: string;
}
export declare function registerOutputs(params: OutputParams): void;
