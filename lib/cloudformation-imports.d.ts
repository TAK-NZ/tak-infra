/**
 * CloudFormation import utilities for base infrastructure resources
 * This file contains constants and functions for importing values from other stacks
 */
/**
 * Common export names for base infrastructure resources (imported from base stack)
 */
export declare const BASE_EXPORT_NAMES: {
    readonly VPC_ID: "VpcId";
    readonly VPC_CIDR_IPV4: "VpcCidrIpv4";
    readonly VPC_CIDR_IPV6: "VpcCidrIpv6";
    readonly SUBNET_PRIVATE_A: "SubnetPrivateA";
    readonly SUBNET_PRIVATE_B: "SubnetPrivateB";
    readonly SUBNET_PUBLIC_A: "SubnetPublicA";
    readonly SUBNET_PUBLIC_B: "SubnetPublicB";
    readonly ECS_CLUSTER: "EcsClusterArn";
    readonly ECR_REPO: "EcrRepoArn";
    readonly KMS_KEY: "KmsKeyArn";
    readonly KMS_ALIAS: "KmsAlias";
    readonly S3_BUCKET: "S3BucketArn";
    readonly S3_ID: "S3-ID";
    readonly CERTIFICATE_ARN: "CertificateArn";
    readonly HOSTED_ZONE_ID: "HostedZoneId";
    readonly HOSTED_ZONE_NAME: "HostedZoneName";
};
/**
 * Helper to create base infrastructure import value names
 * @param environment - Environment name (e.g. 'prod', 'dev', 'test', etc.)
 * @param exportName - The specific export name suffix from BASE_EXPORT_NAMES
 * @returns Full import value reference for base infrastructure
 */
export declare function createBaseImportValue(environment: string, exportName: string): string;
/**
 * Common export names for auth infrastructure resources (imported from auth stack)
 */
export declare const AUTH_EXPORT_NAMES: {
    readonly LDAP_BASE_DN: "LdapBaseDn";
    readonly LDAP_SERVICE_USER_SECRET: "AuthentikLdapServiceUserArn";
    readonly LDAPS_ENDPOINT: "LdapsEndpoint";
};
/**
 * Helper to create auth infrastructure import value names for cross-stack references
 * @param environment - Environment name (e.g. 'prod', 'dev', 'test', etc.)
 * @param exportName - The specific export name suffix
 * @returns Full import value reference for auth infrastructure
 */
export declare function createAuthImportValue(environment: string, exportName: string): string;
