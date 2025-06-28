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

export function registerOutputs(params: OutputParams): void {
  const { stack, stackName } = params;
  
  const outputs = [
    { key: 'DatabaseEndpoint', value: params.databaseEndpoint, description: 'RDS Aurora PostgreSQL cluster endpoint' },
    { key: 'DatabaseSecretArn', value: params.databaseSecretArn, description: 'RDS Aurora PostgreSQL master secret ARN' },
    { key: 'EfsId', value: params.efsId, description: 'EFS file system ID' },
    { key: 'EfsTakCertsAccessPoint', value: params.efsTakCertsAccessPointId, description: 'EFS TAK certs access point ID' },
    { key: 'EfsLetsEncryptAccessPoint', value: params.efsLetsEncryptAccessPointId, description: 'EFS Let\'s Encrypt access point ID' },
    { key: 'TakServerNlbDns', value: params.takServerNlbDns, description: 'TAK Server Network Load Balancer DNS name' },
    { key: 'TakServerUrl', value: params.takServerUrl, description: 'TAK Server application URL' },
    { key: 'TakServerApiUrl', value: params.takServerApiUrl, description: 'TAK Server API URL' },
  ];

  outputs.forEach(({ key, value, description }) => {
    new cdk.CfnOutput(stack, `${key}Output`, {
      value,
      description,
      exportName: `${stackName}-${key}`,
    });
  });
}