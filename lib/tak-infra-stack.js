"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null) for (var k in mod) if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.TakInfraStack = void 0;
const cdk = __importStar(require("aws-cdk-lib"));
const aws_cdk_lib_1 = require("aws-cdk-lib");
const utils_1 = require("./utils");
/**
 * Main CDK stack for the TAK Server Infrastructure
 */
class TakInfraStack extends cdk.Stack {
    constructor(scope, id, props) {
        super(scope, id, {
            ...props,
            description: 'TAK Server Infrastructure - Database, EFS, Load Balancer, ECS Service',
        });
        // Validate configuration early
        (0, utils_1.validateEnvType)(props.environment);
        (0, utils_1.validateStackName)(props.envConfig.stackName);
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
        const stackName = aws_cdk_lib_1.Fn.ref('AWS::StackName');
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
exports.TakInfraStack = TakInfraStack;
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoidGFrLWluZnJhLXN0YWNrLmpzIiwic291cmNlUm9vdCI6IiIsInNvdXJjZXMiOlsidGFrLWluZnJhLXN0YWNrLnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiI7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBQUEsaURBQW1DO0FBRW5DLDZDQUF1RTtBQVl2RSxtQ0FBNkQ7QUFPN0Q7O0dBRUc7QUFDSCxNQUFhLGFBQWMsU0FBUSxHQUFHLENBQUMsS0FBSztJQUMxQyxZQUFZLEtBQWdCLEVBQUUsRUFBVSxFQUFFLEtBQXlCO1FBQ2pFLEtBQUssQ0FBQyxLQUFLLEVBQUUsRUFBRSxFQUFFO1lBQ2YsR0FBRyxLQUFLO1lBQ1IsV0FBVyxFQUFFLHVFQUF1RTtTQUNyRixDQUFDLENBQUM7UUFFSCwrQkFBK0I7UUFDL0IsSUFBQSx1QkFBZSxFQUFDLEtBQUssQ0FBQyxXQUFXLENBQUMsQ0FBQztRQUNuQyxJQUFBLHlCQUFpQixFQUFDLEtBQUssQ0FBQyxTQUFTLENBQUMsU0FBUyxDQUFDLENBQUM7UUFFN0MsNkVBQTZFO1FBQzdFLE1BQU0sRUFBRSxTQUFTLEVBQUUsR0FBRyxLQUFLLENBQUM7UUFFNUIsdURBQXVEO1FBQ3ZELE1BQU0sa0JBQWtCLEdBQUcsU0FBUyxDQUFDLFNBQVMsQ0FBQyxDQUFDLDRDQUE0QztRQUU1RixNQUFNLGtCQUFrQixHQUFHLEtBQUssQ0FBQyxXQUFXLEtBQUssTUFBTSxDQUFDO1FBQ3hELE1BQU0sZ0JBQWdCLEdBQUcsS0FBSyxDQUFDLFdBQVcsS0FBSyxNQUFNLENBQUMsQ0FBQyxDQUFDLE1BQU0sQ0FBQyxDQUFDLENBQUMsVUFBVSxDQUFDO1FBQzVFLE1BQU0saUJBQWlCLEdBQUcsRUFBRSxDQUFDO1FBRTdCLHlDQUF5QztRQUN6QyxNQUFNLHNCQUFzQixHQUFHLGtCQUFrQixDQUFDO1FBQ2xELE1BQU0scUJBQXFCLEdBQUcsU0FBUyxDQUFDLE9BQU8sQ0FBQyxxQkFBcUIsQ0FBQztRQUV0RSwwRUFBMEU7UUFDMUUsTUFBTSxTQUFTLEdBQUcsZ0JBQUUsQ0FBQyxHQUFHLENBQUMsZ0JBQWdCLENBQUMsQ0FBQztRQUMzQyxNQUFNLE1BQU0sR0FBRyxHQUFHLENBQUMsS0FBSyxDQUFDLEVBQUUsQ0FBQyxJQUFJLENBQUMsQ0FBQyxNQUFNLENBQUM7UUFFekMsMkNBQTJDO1FBQzNDLE1BQU0saUJBQWlCLEdBQUcsU0FBUyxDQUFDLFNBQVMsQ0FBQyxRQUFRLENBQUM7UUFDdkQsTUFBTSxpQkFBaUIsR0FBRyxTQUFTLENBQUMsU0FBUyxDQUFDLFFBQVEsQ0FBQztRQUN2RCxNQUFNLGdCQUFnQixHQUFHLFNBQVMsQ0FBQyxTQUFTLENBQUMsT0FBTyxDQUFDO1FBQ3JELE1BQU0sZUFBZSxHQUFHLFNBQVMsQ0FBQyxTQUFTLENBQUMsV0FBVyxDQUFDO1FBQ3hELE1BQU0sYUFBYSxHQUFHLFNBQVMsQ0FBQyxHQUFHLENBQUMsYUFBYSxJQUFJLEtBQUssQ0FBQztRQUUzRCxvQkFBb0I7UUFDcEIsdUNBQXVDO1FBQ3ZDLG9CQUFvQjtRQUVwQiw4RUFBOEU7UUFFOUUsb0JBQW9CO1FBQ3BCLHNCQUFzQjtRQUN0QixvQkFBb0I7UUFFcEIsMkRBQTJEO1FBQzNELGlDQUFpQztRQUNqQyxzQ0FBc0M7UUFDdEMsd0NBQXdDO1FBQ3hDLG9CQUFvQjtRQUNwQiw0Q0FBNEM7UUFDNUMsMEJBQTBCO1FBRTFCLG9CQUFvQjtRQUNwQixnQkFBZ0I7UUFDaEIsb0JBQW9CO1FBRXBCLDBDQUEwQztJQUM1QyxDQUFDO0NBQ0Y7QUE1REQsc0NBNERDIiwic291cmNlc0NvbnRlbnQiOlsiaW1wb3J0ICogYXMgY2RrIGZyb20gJ2F3cy1jZGstbGliJztcbmltcG9ydCB7IENvbnN0cnVjdCB9IGZyb20gJ2NvbnN0cnVjdHMnO1xuaW1wb3J0IHsgUmVtb3ZhbFBvbGljeSwgU3RhY2tQcm9wcywgRm4sIENmbk91dHB1dCB9IGZyb20gJ2F3cy1jZGstbGliJztcbmltcG9ydCAqIGFzIGVjMiBmcm9tICdhd3MtY2RrLWxpYi9hd3MtZWMyJztcbmltcG9ydCAqIGFzIGVjcyBmcm9tICdhd3MtY2RrLWxpYi9hd3MtZWNzJztcbmltcG9ydCAqIGFzIGttcyBmcm9tICdhd3MtY2RrLWxpYi9hd3Mta21zJztcbmltcG9ydCAqIGFzIHMzIGZyb20gJ2F3cy1jZGstbGliL2F3cy1zMyc7XG5cbi8vIENvbnN0cnVjdCBpbXBvcnRzXG4vLyBUT0RPOiBJbXBvcnQgY29uc3RydWN0cyBpbiBQaGFzZSAyXG5cbi8vIFV0aWxpdHkgaW1wb3J0c1xuaW1wb3J0IHsgY3JlYXRlQmFzZUltcG9ydFZhbHVlLCBCQVNFX0VYUE9SVF9OQU1FUyB9IGZyb20gJy4vY2xvdWRmb3JtYXRpb24taW1wb3J0cyc7XG5pbXBvcnQgeyBDb250ZXh0RW52aXJvbm1lbnRDb25maWcgfSBmcm9tICcuL3N0YWNrLWNvbmZpZyc7XG5pbXBvcnQgeyB2YWxpZGF0ZUVudlR5cGUsIHZhbGlkYXRlU3RhY2tOYW1lIH0gZnJvbSAnLi91dGlscyc7XG5cbmV4cG9ydCBpbnRlcmZhY2UgVGFrSW5mcmFTdGFja1Byb3BzIGV4dGVuZHMgU3RhY2tQcm9wcyB7XG4gIGVudmlyb25tZW50OiAncHJvZCcgfCAnZGV2LXRlc3QnO1xuICBlbnZDb25maWc6IENvbnRleHRFbnZpcm9ubWVudENvbmZpZzsgLy8gRW52aXJvbm1lbnQgY29uZmlndXJhdGlvbiBmcm9tIGNvbnRleHRcbn1cblxuLyoqXG4gKiBNYWluIENESyBzdGFjayBmb3IgdGhlIFRBSyBTZXJ2ZXIgSW5mcmFzdHJ1Y3R1cmVcbiAqL1xuZXhwb3J0IGNsYXNzIFRha0luZnJhU3RhY2sgZXh0ZW5kcyBjZGsuU3RhY2sge1xuICBjb25zdHJ1Y3RvcihzY29wZTogQ29uc3RydWN0LCBpZDogc3RyaW5nLCBwcm9wczogVGFrSW5mcmFTdGFja1Byb3BzKSB7XG4gICAgc3VwZXIoc2NvcGUsIGlkLCB7XG4gICAgICAuLi5wcm9wcyxcbiAgICAgIGRlc2NyaXB0aW9uOiAnVEFLIFNlcnZlciBJbmZyYXN0cnVjdHVyZSAtIERhdGFiYXNlLCBFRlMsIExvYWQgQmFsYW5jZXIsIEVDUyBTZXJ2aWNlJyxcbiAgICB9KTtcblxuICAgIC8vIFZhbGlkYXRlIGNvbmZpZ3VyYXRpb24gZWFybHlcbiAgICB2YWxpZGF0ZUVudlR5cGUocHJvcHMuZW52aXJvbm1lbnQpO1xuICAgIHZhbGlkYXRlU3RhY2tOYW1lKHByb3BzLmVudkNvbmZpZy5zdGFja05hbWUpO1xuXG4gICAgLy8gVXNlIGVudmlyb25tZW50IGNvbmZpZ3VyYXRpb24gZGlyZWN0bHkgKG5vIGNvbXBsZXggdHJhbnNmb3JtYXRpb25zIG5lZWRlZClcbiAgICBjb25zdCB7IGVudkNvbmZpZyB9ID0gcHJvcHM7XG4gICAgXG4gICAgLy8gRXh0cmFjdCBjb25maWd1cmF0aW9uIHZhbHVlcyBkaXJlY3RseSBmcm9tIGVudkNvbmZpZ1xuICAgIGNvbnN0IHN0YWNrTmFtZUNvbXBvbmVudCA9IGVudkNvbmZpZy5zdGFja05hbWU7IC8vIFRoaXMgaXMgdGhlIFNUQUNLX05BTUUgcGFydCAoZS5nLiwgXCJEZXZcIilcbiAgICBcbiAgICBjb25zdCBpc0hpZ2hBdmFpbGFiaWxpdHkgPSBwcm9wcy5lbnZpcm9ubWVudCA9PT0gJ3Byb2QnO1xuICAgIGNvbnN0IGVudmlyb25tZW50TGFiZWwgPSBwcm9wcy5lbnZpcm9ubWVudCA9PT0gJ3Byb2QnID8gJ1Byb2QnIDogJ0Rldi1UZXN0JztcbiAgICBjb25zdCByZXNvbHZlZFN0YWNrTmFtZSA9IGlkO1xuICAgIFxuICAgIC8vIFVzZSBjb21wdXRlZCB2YWx1ZXMgZnJvbSBjb25maWd1cmF0aW9uXG4gICAgY29uc3QgZW5hYmxlSGlnaEF2YWlsYWJpbGl0eSA9IGlzSGlnaEF2YWlsYWJpbGl0eTtcbiAgICBjb25zdCBlbmFibGVEZXRhaWxlZExvZ2dpbmcgPSBlbnZDb25maWcuZ2VuZXJhbC5lbmFibGVEZXRhaWxlZExvZ2dpbmc7XG5cbiAgICAvLyBHZXQgcnVudGltZSBDbG91ZEZvcm1hdGlvbiB2YWx1ZXMgZm9yIHN0YWNrIG91dHB1dHMgYW5kIHJlc291cmNlIG5hbWluZ1xuICAgIGNvbnN0IHN0YWNrTmFtZSA9IEZuLnJlZignQVdTOjpTdGFja05hbWUnKTtcbiAgICBjb25zdCByZWdpb24gPSBjZGsuU3RhY2sub2YodGhpcykucmVnaW9uO1xuXG4gICAgLy8gQ29uZmlndXJhdGlvbi1iYXNlZCBwYXJhbWV0ZXIgcmVzb2x1dGlvblxuICAgIGNvbnN0IHRha1NlcnZlckhvc3RuYW1lID0gZW52Q29uZmlnLnRha3NlcnZlci5ob3N0bmFtZTtcbiAgICBjb25zdCB0YWtTZXJ2ZXJCcmFuZGluZyA9IGVudkNvbmZpZy50YWtzZXJ2ZXIuYnJhbmRpbmc7XG4gICAgY29uc3QgdGFrU2VydmVyVmVyc2lvbiA9IGVudkNvbmZpZy50YWtzZXJ2ZXIudmVyc2lvbjtcbiAgICBjb25zdCB1c2VTM0NvbmZpZ0ZpbGUgPSBlbnZDb25maWcudGFrc2VydmVyLnVzZVMzQ29uZmlnO1xuICAgIGNvbnN0IGVuYWJsZUVjc0V4ZWMgPSBlbnZDb25maWcuZWNzLmVuYWJsZUVjc0V4ZWMgPz8gZmFsc2U7XG5cbiAgICAvLyA9PT09PT09PT09PT09PT09PVxuICAgIC8vIElNUE9SVCBCQVNFIElORlJBU1RSVUNUVVJFIFJFU09VUkNFU1xuICAgIC8vID09PT09PT09PT09PT09PT09XG5cbiAgICAvLyBUT0RPOiBJbXBvcnQgVlBDLCBFQ1MgY2x1c3RlciwgS01TLCBTMywgUm91dGU1MywgQUNNIGNlcnRpZmljYXRlIGluIFBoYXNlIDJcbiAgICBcbiAgICAvLyA9PT09PT09PT09PT09PT09PVxuICAgIC8vIENPUkUgSU5GUkFTVFJVQ1RVUkVcbiAgICAvLyA9PT09PT09PT09PT09PT09PVxuXG4gICAgLy8gVE9ETzogSW1wbGVtZW50IFRBSyBpbmZyYXN0cnVjdHVyZSBjb25zdHJ1Y3RzIGluIFBoYXNlIDJcbiAgICAvLyAtIERhdGFiYXNlIChQb3N0Z3JlU1FMIEF1cm9yYSlcbiAgICAvLyAtIEVGUyAoRmlsZSBTeXN0ZW0gKyBBY2Nlc3MgUG9pbnRzKVxuICAgIC8vIC0gTG9hZCBCYWxhbmNlciAoTkxCICsgVGFyZ2V0IEdyb3VwcylcbiAgICAvLyAtIFNlY3VyaXR5IEdyb3Vwc1xuICAgIC8vIC0gRUNTIFNlcnZpY2UgKFRhc2sgRGVmaW5pdGlvbiArIFNlcnZpY2UpXG4gICAgLy8gLSBSb3V0ZTUzIChETlMgUmVjb3JkcylcbiAgICBcbiAgICAvLyA9PT09PT09PT09PT09PT09PVxuICAgIC8vIFNUQUNLIE9VVFBVVFNcbiAgICAvLyA9PT09PT09PT09PT09PT09PVxuXG4gICAgLy8gVE9ETzogUmVnaXN0ZXIgc3RhY2sgb3V0cHV0cyBpbiBQaGFzZSAyXG4gIH1cbn0iXX0=