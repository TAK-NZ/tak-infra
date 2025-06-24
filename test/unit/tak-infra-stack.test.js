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
        takserver: { hostname: 'tak', servicename: 'ops', branding: 'generic', version: '5.4-RELEASE-19', useS3Config: false },
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
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoidGFrLWluZnJhLXN0YWNrLnRlc3QuanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyJ0YWstaW5mcmEtc3RhY2sudGVzdC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBQUEsaURBQW1DO0FBQ25DLHVEQUFrRDtBQUNsRCwrREFBMEQ7QUFHMUQsSUFBSSxDQUFDLG9DQUFvQyxFQUFFLEdBQUcsRUFBRTtJQUM5QyxNQUFNLEdBQUcsR0FBRyxJQUFJLEdBQUcsQ0FBQyxHQUFHLEVBQUUsQ0FBQztJQUMxQixNQUFNLFNBQVMsR0FBNkI7UUFDMUMsU0FBUyxFQUFFLE1BQU07UUFDakIsUUFBUSxFQUFFO1lBQ1IsYUFBYSxFQUFFLGVBQWU7WUFDOUIsYUFBYSxFQUFFLENBQUM7WUFDaEIsbUJBQW1CLEVBQUUsQ0FBQztZQUN0QixnQkFBZ0IsRUFBRSxLQUFLO1NBQ3hCO1FBQ0QsR0FBRyxFQUFFLEVBQUUsT0FBTyxFQUFFLElBQUksRUFBRSxVQUFVLEVBQUUsSUFBSSxFQUFFLFlBQVksRUFBRSxDQUFDLEVBQUU7UUFDekQsU0FBUyxFQUFFLEVBQUUsUUFBUSxFQUFFLEtBQUssRUFBRSxXQUFXLEVBQUUsS0FBSyxFQUFFLFFBQVEsRUFBRSxTQUFTLEVBQUUsT0FBTyxFQUFFLGdCQUFnQixFQUFFLFdBQVcsRUFBRSxLQUFLLEVBQUU7UUFDdEgsT0FBTyxFQUFFLEVBQUUsYUFBYSxFQUFFLFNBQVMsRUFBRSxxQkFBcUIsRUFBRSxJQUFJLEVBQUU7S0FDbkUsQ0FBQztJQUVGLE1BQU0sS0FBSyxHQUFHLElBQUksK0JBQWEsQ0FBQyxHQUFHLEVBQUUsbUJBQW1CLEVBQUU7UUFDeEQsV0FBVyxFQUFFLFVBQVU7UUFDdkIsU0FBUztLQUNWLENBQUMsQ0FBQztJQUNILE1BQU0sUUFBUSxHQUFHLHFCQUFRLENBQUMsU0FBUyxDQUFDLEtBQUssQ0FBQyxDQUFDO0lBRTNDLHdEQUF3RDtJQUN4RCxNQUFNLENBQUMsUUFBUSxDQUFDLENBQUMsV0FBVyxFQUFFLENBQUM7QUFDakMsQ0FBQyxDQUFDLENBQUMiLCJzb3VyY2VzQ29udGVudCI6WyJpbXBvcnQgKiBhcyBjZGsgZnJvbSAnYXdzLWNkay1saWInO1xuaW1wb3J0IHsgVGVtcGxhdGUgfSBmcm9tICdhd3MtY2RrLWxpYi9hc3NlcnRpb25zJztcbmltcG9ydCB7IFRha0luZnJhU3RhY2sgfSBmcm9tICcuLi8uLi9saWIvdGFrLWluZnJhLXN0YWNrJztcbmltcG9ydCB7IENvbnRleHRFbnZpcm9ubWVudENvbmZpZyB9IGZyb20gJy4uLy4uL2xpYi9zdGFjay1jb25maWcnO1xuXG50ZXN0KCdUYWtJbmZyYVN0YWNrIGNyZWF0ZXMgc3VjY2Vzc2Z1bGx5JywgKCkgPT4ge1xuICBjb25zdCBhcHAgPSBuZXcgY2RrLkFwcCgpO1xuICBjb25zdCBlbnZDb25maWc6IENvbnRleHRFbnZpcm9ubWVudENvbmZpZyA9IHtcbiAgICBzdGFja05hbWU6ICdUZXN0JyxcbiAgICBkYXRhYmFzZTogeyBcbiAgICAgIGluc3RhbmNlQ2xhc3M6ICdkYi5zZXJ2ZXJsZXNzJyxcbiAgICAgIGluc3RhbmNlQ291bnQ6IDEsXG4gICAgICBiYWNrdXBSZXRlbnRpb25EYXlzOiA3LFxuICAgICAgZGVsZXRlUHJvdGVjdGlvbjogZmFsc2VcbiAgICB9LFxuICAgIGVjczogeyB0YXNrQ3B1OiAxMDI0LCB0YXNrTWVtb3J5OiAyMDQ4LCBkZXNpcmVkQ291bnQ6IDEgfSxcbiAgICB0YWtzZXJ2ZXI6IHsgaG9zdG5hbWU6ICd0YWsnLCBzZXJ2aWNlbmFtZTogJ29wcycsIGJyYW5kaW5nOiAnZ2VuZXJpYycsIHZlcnNpb246ICc1LjQtUkVMRUFTRS0xOScsIHVzZVMzQ29uZmlnOiBmYWxzZSB9LFxuICAgIGdlbmVyYWw6IHsgcmVtb3ZhbFBvbGljeTogJ0RFU1RST1knLCBlbmFibGVEZXRhaWxlZExvZ2dpbmc6IHRydWUgfVxuICB9O1xuICBcbiAgY29uc3Qgc3RhY2sgPSBuZXcgVGFrSW5mcmFTdGFjayhhcHAsICdUZXN0VGFrSW5mcmFTdGFjaycsIHsgXG4gICAgZW52aXJvbm1lbnQ6ICdkZXYtdGVzdCcsXG4gICAgZW52Q29uZmlnXG4gIH0pO1xuICBjb25zdCB0ZW1wbGF0ZSA9IFRlbXBsYXRlLmZyb21TdGFjayhzdGFjayk7XG4gIFxuICAvLyBCYXNpYyB0ZXN0IHRvIGVuc3VyZSBzdGFjayBzeW50aGVzaXplcyB3aXRob3V0IGVycm9yc1xuICBleHBlY3QodGVtcGxhdGUpLnRvQmVEZWZpbmVkKCk7XG59KTsiXX0=