/**
 * Utility functions for CDK infrastructure
 */

/**
 * Validates environment type parameter
 * @param envType - The environment type to validate
 * @throws Error if envType is not valid
 */
export function validateEnvType(envType: string): void {
  if (envType !== 'prod' && envType !== 'dev-test') {
    throw new Error(`Invalid envType: ${envType}. Must be 'prod' or 'dev-test'`);
  }
}

/**
 * Validates required stack name parameter
 * @param stackName - The stack name to validate
 * @throws Error if stackName is missing or empty
 */
export function validateStackName(stackName: string | undefined): void {
  if (!stackName) {
    throw new Error('stackName is required. Use --context stackName=YourStackName');
  }
}

/**
 * Gets the current Git SHA for tagging resources
 * @returns Git SHA string or 'unknown' if not available
 */
export function getGitSha(): string {
  try {
    const { execSync } = require('child_process');
    return execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
  } catch (error) {
    return 'unknown';
  }
}