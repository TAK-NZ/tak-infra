/**
 * Utility functions for CDK infrastructure
 */
/**
 * Validates environment type parameter
 * @param envType - The environment type to validate
 * @throws Error if envType is not valid
 */
export declare function validateEnvType(envType: string): void;
/**
 * Validates required stack name parameter
 * @param stackName - The stack name to validate
 * @throws Error if stackName is missing or empty
 */
export declare function validateStackName(stackName: string | undefined): void;
/**
 * Gets the current Git SHA for tagging resources
 * @returns Git SHA string or 'unknown' if not available
 */
export declare function getGitSha(): string;
