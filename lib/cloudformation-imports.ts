/**
 * CloudFormation import utilities for base infrastructure resources
 * This file contains constants and functions for importing values from other stacks
 */

/**
 * Common export names for base infrastructure resources (imported from base stack)
 */
export const BASE_EXPORT_NAMES = {
  VPC_ID: 'VpcId',
  VPC_CIDR_IPV4: 'VpcCidrIpv4',
  VPC_CIDR_IPV6: 'VpcCidrIpv6',
  SUBNET_PRIVATE_A: 'SubnetPrivateA',
  SUBNET_PRIVATE_B: 'SubnetPrivateB',
  SUBNET_PUBLIC_A: 'SubnetPublicA',
  SUBNET_PUBLIC_B: 'SubnetPublicB',
  ECS_CLUSTER: 'EcsClusterArn',
  ECR_REPO: 'EcrRepoArn',
  KMS_KEY: 'KmsKeyArn',
  KMS_ALIAS: 'KmsAlias',
  S3_BUCKET: 'S3BucketArn',
  S3_TAK_IMAGES: 'S3TAKImagesArn',
  S3_ID: 'S3-ID',
  CERTIFICATE_ARN: 'CertificateArn',
  HOSTED_ZONE_ID: 'HostedZoneId',
  HOSTED_ZONE_NAME: 'HostedZoneName',
} as const;

/**
 * Helper to create base infrastructure import value names
 * @param environment - Environment name (e.g. 'prod', 'dev', 'test', etc.)
 * @param exportName - The specific export name suffix from BASE_EXPORT_NAMES
 * @returns Full import value reference for base infrastructure
 */
export function createBaseImportValue(environment: string, exportName: string): string {
  const baseStackName = `TAK-${environment}-BaseInfra`;
  return `${baseStackName}-${exportName}`;
}

/**
 * Common export names for auth infrastructure resources (imported from auth stack)
 */
export const AUTH_EXPORT_NAMES = {
  LDAP_BASE_DN: 'LdapBaseDn',
  LDAP_SERVICE_USER_SECRET: 'AuthentikLdapServiceUserArn',
  LDAPS_ENDPOINT: 'LdapsEndpoint',
} as const;

/**
 * Helper to create auth infrastructure import value names for cross-stack references
 * @param environment - Environment name (e.g. 'prod', 'dev', 'test', etc.)  
 * @param exportName - The specific export name suffix
 * @returns Full import value reference for auth infrastructure
 */
export function createAuthImportValue(environment: string, exportName: string): string {
  const authStackName = `TAK-${environment}-AuthInfra`;
  return `${authStackName}-${exportName}`;
}