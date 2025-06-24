"use strict";
/**
 * Utility functions for CDK infrastructure
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.validateEnvType = validateEnvType;
exports.validateStackName = validateStackName;
exports.getGitSha = getGitSha;
/**
 * Validates environment type parameter
 * @param envType - The environment type to validate
 * @throws Error if envType is not valid
 */
function validateEnvType(envType) {
    if (envType !== 'prod' && envType !== 'dev-test') {
        throw new Error(`Invalid envType: ${envType}. Must be 'prod' or 'dev-test'`);
    }
}
/**
 * Validates required stack name parameter
 * @param stackName - The stack name to validate
 * @throws Error if stackName is missing or empty
 */
function validateStackName(stackName) {
    if (!stackName) {
        throw new Error('stackName is required. Use --context stackName=YourStackName');
    }
}
/**
 * Gets the current Git SHA for tagging resources
 * @returns Git SHA string or 'unknown' if not available
 */
function getGitSha() {
    try {
        const { execSync } = require('child_process');
        return execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
    }
    catch (error) {
        return 'unknown';
    }
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoidXRpbHMuanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyJ1dGlscy50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiO0FBQUE7O0dBRUc7O0FBT0gsMENBSUM7QUFPRCw4Q0FJQztBQU1ELDhCQU9DO0FBakNEOzs7O0dBSUc7QUFDSCxTQUFnQixlQUFlLENBQUMsT0FBZTtJQUM3QyxJQUFJLE9BQU8sS0FBSyxNQUFNLElBQUksT0FBTyxLQUFLLFVBQVUsRUFBRSxDQUFDO1FBQ2pELE1BQU0sSUFBSSxLQUFLLENBQUMsb0JBQW9CLE9BQU8sZ0NBQWdDLENBQUMsQ0FBQztJQUMvRSxDQUFDO0FBQ0gsQ0FBQztBQUVEOzs7O0dBSUc7QUFDSCxTQUFnQixpQkFBaUIsQ0FBQyxTQUE2QjtJQUM3RCxJQUFJLENBQUMsU0FBUyxFQUFFLENBQUM7UUFDZixNQUFNLElBQUksS0FBSyxDQUFDLDhEQUE4RCxDQUFDLENBQUM7SUFDbEYsQ0FBQztBQUNILENBQUM7QUFFRDs7O0dBR0c7QUFDSCxTQUFnQixTQUFTO0lBQ3ZCLElBQUksQ0FBQztRQUNILE1BQU0sRUFBRSxRQUFRLEVBQUUsR0FBRyxPQUFPLENBQUMsZUFBZSxDQUFDLENBQUM7UUFDOUMsT0FBTyxRQUFRLENBQUMsb0JBQW9CLEVBQUUsRUFBRSxRQUFRLEVBQUUsTUFBTSxFQUFFLENBQUMsQ0FBQyxJQUFJLEVBQUUsQ0FBQztJQUNyRSxDQUFDO0lBQUMsT0FBTyxLQUFLLEVBQUUsQ0FBQztRQUNmLE9BQU8sU0FBUyxDQUFDO0lBQ25CLENBQUM7QUFDSCxDQUFDIiwic291cmNlc0NvbnRlbnQiOlsiLyoqXG4gKiBVdGlsaXR5IGZ1bmN0aW9ucyBmb3IgQ0RLIGluZnJhc3RydWN0dXJlXG4gKi9cblxuLyoqXG4gKiBWYWxpZGF0ZXMgZW52aXJvbm1lbnQgdHlwZSBwYXJhbWV0ZXJcbiAqIEBwYXJhbSBlbnZUeXBlIC0gVGhlIGVudmlyb25tZW50IHR5cGUgdG8gdmFsaWRhdGVcbiAqIEB0aHJvd3MgRXJyb3IgaWYgZW52VHlwZSBpcyBub3QgdmFsaWRcbiAqL1xuZXhwb3J0IGZ1bmN0aW9uIHZhbGlkYXRlRW52VHlwZShlbnZUeXBlOiBzdHJpbmcpOiB2b2lkIHtcbiAgaWYgKGVudlR5cGUgIT09ICdwcm9kJyAmJiBlbnZUeXBlICE9PSAnZGV2LXRlc3QnKSB7XG4gICAgdGhyb3cgbmV3IEVycm9yKGBJbnZhbGlkIGVudlR5cGU6ICR7ZW52VHlwZX0uIE11c3QgYmUgJ3Byb2QnIG9yICdkZXYtdGVzdCdgKTtcbiAgfVxufVxuXG4vKipcbiAqIFZhbGlkYXRlcyByZXF1aXJlZCBzdGFjayBuYW1lIHBhcmFtZXRlclxuICogQHBhcmFtIHN0YWNrTmFtZSAtIFRoZSBzdGFjayBuYW1lIHRvIHZhbGlkYXRlXG4gKiBAdGhyb3dzIEVycm9yIGlmIHN0YWNrTmFtZSBpcyBtaXNzaW5nIG9yIGVtcHR5XG4gKi9cbmV4cG9ydCBmdW5jdGlvbiB2YWxpZGF0ZVN0YWNrTmFtZShzdGFja05hbWU6IHN0cmluZyB8IHVuZGVmaW5lZCk6IHZvaWQge1xuICBpZiAoIXN0YWNrTmFtZSkge1xuICAgIHRocm93IG5ldyBFcnJvcignc3RhY2tOYW1lIGlzIHJlcXVpcmVkLiBVc2UgLS1jb250ZXh0IHN0YWNrTmFtZT1Zb3VyU3RhY2tOYW1lJyk7XG4gIH1cbn1cblxuLyoqXG4gKiBHZXRzIHRoZSBjdXJyZW50IEdpdCBTSEEgZm9yIHRhZ2dpbmcgcmVzb3VyY2VzXG4gKiBAcmV0dXJucyBHaXQgU0hBIHN0cmluZyBvciAndW5rbm93bicgaWYgbm90IGF2YWlsYWJsZVxuICovXG5leHBvcnQgZnVuY3Rpb24gZ2V0R2l0U2hhKCk6IHN0cmluZyB7XG4gIHRyeSB7XG4gICAgY29uc3QgeyBleGVjU3luYyB9ID0gcmVxdWlyZSgnY2hpbGRfcHJvY2VzcycpO1xuICAgIHJldHVybiBleGVjU3luYygnZ2l0IHJldi1wYXJzZSBIRUFEJywgeyBlbmNvZGluZzogJ3V0ZjgnIH0pLnRyaW0oKTtcbiAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICByZXR1cm4gJ3Vua25vd24nO1xuICB9XG59Il19