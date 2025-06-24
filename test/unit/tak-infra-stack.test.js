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
const cdk = __importStar(require("aws-cdk-lib"));
const assertions_1 = require("aws-cdk-lib/assertions");
const tak_infra_stack_1 = require("../../lib/tak-infra-stack");
test('TakInfraStack creates successfully', () => {
    const app = new cdk.App();
    const envConfig = {
        stackName: 'Test',
        database: {
            instanceClass: 'db.serverless',
            instanceCount: 1,
            backupRetentionDays: 7,
            deleteProtection: false
        },
        ecs: { taskCpu: 1024, taskMemory: 2048, desiredCount: 1 },
        takserver: { hostname: 'tak', branding: 'generic', version: '5.4-RELEASE-19', useS3Config: false },
        general: { removalPolicy: 'DESTROY', enableDetailedLogging: true }
    };
    const stack = new tak_infra_stack_1.TakInfraStack(app, 'TestTakInfraStack', {
        environment: 'dev-test',
        envConfig
    });
    const template = assertions_1.Template.fromStack(stack);
    // Basic test to ensure stack synthesizes without errors
    expect(template).toBeDefined();
});
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoidGFrLWluZnJhLXN0YWNrLnRlc3QuanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyJ0YWstaW5mcmEtc3RhY2sudGVzdC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBQUEsaURBQW1DO0FBQ25DLHVEQUFrRDtBQUNsRCwrREFBMEQ7QUFHMUQsSUFBSSxDQUFDLG9DQUFvQyxFQUFFLEdBQUcsRUFBRTtJQUM5QyxNQUFNLEdBQUcsR0FBRyxJQUFJLEdBQUcsQ0FBQyxHQUFHLEVBQUUsQ0FBQztJQUMxQixNQUFNLFNBQVMsR0FBNkI7UUFDMUMsU0FBUyxFQUFFLE1BQU07UUFDakIsUUFBUSxFQUFFO1lBQ1IsYUFBYSxFQUFFLGVBQWU7WUFDOUIsYUFBYSxFQUFFLENBQUM7WUFDaEIsbUJBQW1CLEVBQUUsQ0FBQztZQUN0QixnQkFBZ0IsRUFBRSxLQUFLO1NBQ3hCO1FBQ0QsR0FBRyxFQUFFLEVBQUUsT0FBTyxFQUFFLElBQUksRUFBRSxVQUFVLEVBQUUsSUFBSSxFQUFFLFlBQVksRUFBRSxDQUFDLEVBQUU7UUFDekQsU0FBUyxFQUFFLEVBQUUsUUFBUSxFQUFFLEtBQUssRUFBRSxRQUFRLEVBQUUsU0FBUyxFQUFFLE9BQU8sRUFBRSxnQkFBZ0IsRUFBRSxXQUFXLEVBQUUsS0FBSyxFQUFFO1FBQ2xHLE9BQU8sRUFBRSxFQUFFLGFBQWEsRUFBRSxTQUFTLEVBQUUscUJBQXFCLEVBQUUsSUFBSSxFQUFFO0tBQ25FLENBQUM7SUFFRixNQUFNLEtBQUssR0FBRyxJQUFJLCtCQUFhLENBQUMsR0FBRyxFQUFFLG1CQUFtQixFQUFFO1FBQ3hELFdBQVcsRUFBRSxVQUFVO1FBQ3ZCLFNBQVM7S0FDVixDQUFDLENBQUM7SUFDSCxNQUFNLFFBQVEsR0FBRyxxQkFBUSxDQUFDLFNBQVMsQ0FBQyxLQUFLLENBQUMsQ0FBQztJQUUzQyx3REFBd0Q7SUFDeEQsTUFBTSxDQUFDLFFBQVEsQ0FBQyxDQUFDLFdBQVcsRUFBRSxDQUFDO0FBQ2pDLENBQUMsQ0FBQyxDQUFDIiwic291cmNlc0NvbnRlbnQiOlsiaW1wb3J0ICogYXMgY2RrIGZyb20gJ2F3cy1jZGstbGliJztcbmltcG9ydCB7IFRlbXBsYXRlIH0gZnJvbSAnYXdzLWNkay1saWIvYXNzZXJ0aW9ucyc7XG5pbXBvcnQgeyBUYWtJbmZyYVN0YWNrIH0gZnJvbSAnLi4vLi4vbGliL3Rhay1pbmZyYS1zdGFjayc7XG5pbXBvcnQgeyBDb250ZXh0RW52aXJvbm1lbnRDb25maWcgfSBmcm9tICcuLi8uLi9saWIvc3RhY2stY29uZmlnJztcblxudGVzdCgnVGFrSW5mcmFTdGFjayBjcmVhdGVzIHN1Y2Nlc3NmdWxseScsICgpID0+IHtcbiAgY29uc3QgYXBwID0gbmV3IGNkay5BcHAoKTtcbiAgY29uc3QgZW52Q29uZmlnOiBDb250ZXh0RW52aXJvbm1lbnRDb25maWcgPSB7XG4gICAgc3RhY2tOYW1lOiAnVGVzdCcsXG4gICAgZGF0YWJhc2U6IHsgXG4gICAgICBpbnN0YW5jZUNsYXNzOiAnZGIuc2VydmVybGVzcycsXG4gICAgICBpbnN0YW5jZUNvdW50OiAxLFxuICAgICAgYmFja3VwUmV0ZW50aW9uRGF5czogNyxcbiAgICAgIGRlbGV0ZVByb3RlY3Rpb246IGZhbHNlXG4gICAgfSxcbiAgICBlY3M6IHsgdGFza0NwdTogMTAyNCwgdGFza01lbW9yeTogMjA0OCwgZGVzaXJlZENvdW50OiAxIH0sXG4gICAgdGFrc2VydmVyOiB7IGhvc3RuYW1lOiAndGFrJywgYnJhbmRpbmc6ICdnZW5lcmljJywgdmVyc2lvbjogJzUuNC1SRUxFQVNFLTE5JywgdXNlUzNDb25maWc6IGZhbHNlIH0sXG4gICAgZ2VuZXJhbDogeyByZW1vdmFsUG9saWN5OiAnREVTVFJPWScsIGVuYWJsZURldGFpbGVkTG9nZ2luZzogdHJ1ZSB9XG4gIH07XG4gIFxuICBjb25zdCBzdGFjayA9IG5ldyBUYWtJbmZyYVN0YWNrKGFwcCwgJ1Rlc3RUYWtJbmZyYVN0YWNrJywgeyBcbiAgICBlbnZpcm9ubWVudDogJ2Rldi10ZXN0JyxcbiAgICBlbnZDb25maWdcbiAgfSk7XG4gIGNvbnN0IHRlbXBsYXRlID0gVGVtcGxhdGUuZnJvbVN0YWNrKHN0YWNrKTtcbiAgXG4gIC8vIEJhc2ljIHRlc3QgdG8gZW5zdXJlIHN0YWNrIHN5bnRoZXNpemVzIHdpdGhvdXQgZXJyb3JzXG4gIGV4cGVjdCh0ZW1wbGF0ZSkudG9CZURlZmluZWQoKTtcbn0pOyJdfQ==