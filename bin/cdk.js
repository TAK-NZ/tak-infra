#!/usr/bin/env node
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
const tak_infra_stack_1 = require("../lib/tak-infra-stack");
const context_overrides_1 = require("../lib/utils/context-overrides");
const constants_1 = require("../lib/utils/constants");
const tag_helpers_1 = require("../lib/utils/tag-helpers");
const app = new cdk.App();
// Get environment from context (defaults to dev-test)
const envName = app.node.tryGetContext('env') || 'dev-test';
// Get the environment configuration from context
// CDK automatically handles context overrides via --context flag
const envConfig = app.node.tryGetContext(envName);
const defaults = app.node.tryGetContext('tak-defaults');
if (!envConfig) {
    throw new Error(`
❌ Environment configuration for '${envName}' not found in cdk.json

Usage:
  npx cdk deploy --context env=dev-test
  npx cdk deploy --context env=prod

Expected cdk.json structure:
{
  "context": {
    "dev-test": { ... },
    "prod": { ... }
  }
}
  `);
}
// Apply context overrides for non-prefixed parameters
// This supports direct overrides that work for any environment:
// --context takServerHostname=custom-tak
// --context branding=custom-brand
const finalEnvConfig = (0, context_overrides_1.applyContextOverrides)(app, envConfig);
// Create stack name
const stackName = `TAK-${finalEnvConfig.stackName}-TakInfra`;
// Create the stack
const stack = new tak_infra_stack_1.TakInfraStack(app, stackName, {
    environment: envName,
    envConfig: finalEnvConfig,
    env: {
        account: process.env.CDK_DEFAULT_ACCOUNT,
        region: process.env.CDK_DEFAULT_REGION || defaults?.region || constants_1.DEFAULT_AWS_REGION,
    },
    tags: (0, tag_helpers_1.generateStandardTags)(finalEnvConfig, envName, defaults)
});
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiY2RrLmpzIiwic291cmNlUm9vdCI6IiIsInNvdXJjZXMiOlsiY2RrLnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiI7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBQ0EsaURBQW1DO0FBQ25DLDREQUF1RDtBQUN2RCxzRUFBdUU7QUFDdkUsc0RBQTREO0FBQzVELDBEQUFnRTtBQUVoRSxNQUFNLEdBQUcsR0FBRyxJQUFJLEdBQUcsQ0FBQyxHQUFHLEVBQUUsQ0FBQztBQUUxQixzREFBc0Q7QUFDdEQsTUFBTSxPQUFPLEdBQUcsR0FBRyxDQUFDLElBQUksQ0FBQyxhQUFhLENBQUMsS0FBSyxDQUFDLElBQUksVUFBVSxDQUFDO0FBRTVELGlEQUFpRDtBQUNqRCxpRUFBaUU7QUFDakUsTUFBTSxTQUFTLEdBQUcsR0FBRyxDQUFDLElBQUksQ0FBQyxhQUFhLENBQUMsT0FBTyxDQUFDLENBQUM7QUFDbEQsTUFBTSxRQUFRLEdBQUcsR0FBRyxDQUFDLElBQUksQ0FBQyxhQUFhLENBQUMsY0FBYyxDQUFDLENBQUM7QUFFeEQsSUFBSSxDQUFDLFNBQVMsRUFBRSxDQUFDO0lBQ2YsTUFBTSxJQUFJLEtBQUssQ0FBQzttQ0FDaUIsT0FBTzs7Ozs7Ozs7Ozs7OztHQWF2QyxDQUFDLENBQUM7QUFDTCxDQUFDO0FBRUQsc0RBQXNEO0FBQ3RELGdFQUFnRTtBQUNoRSx5Q0FBeUM7QUFDekMsa0NBQWtDO0FBQ2xDLE1BQU0sY0FBYyxHQUFHLElBQUEseUNBQXFCLEVBQUMsR0FBRyxFQUFFLFNBQVMsQ0FBQyxDQUFDO0FBRTdELG9CQUFvQjtBQUNwQixNQUFNLFNBQVMsR0FBRyxPQUFPLGNBQWMsQ0FBQyxTQUFTLFdBQVcsQ0FBQztBQUU3RCxtQkFBbUI7QUFDbkIsTUFBTSxLQUFLLEdBQUcsSUFBSSwrQkFBYSxDQUFDLEdBQUcsRUFBRSxTQUFTLEVBQUU7SUFDOUMsV0FBVyxFQUFFLE9BQThCO0lBQzNDLFNBQVMsRUFBRSxjQUFjO0lBQ3pCLEdBQUcsRUFBRTtRQUNILE9BQU8sRUFBRSxPQUFPLENBQUMsR0FBRyxDQUFDLG1CQUFtQjtRQUN4QyxNQUFNLEVBQUUsT0FBTyxDQUFDLEdBQUcsQ0FBQyxrQkFBa0IsSUFBSSxRQUFRLEVBQUUsTUFBTSxJQUFJLDhCQUFrQjtLQUNqRjtJQUNELElBQUksRUFBRSxJQUFBLGtDQUFvQixFQUFDLGNBQWMsRUFBRSxPQUE4QixFQUFFLFFBQVEsQ0FBQztDQUNyRixDQUFDLENBQUMiLCJzb3VyY2VzQ29udGVudCI6WyIjIS91c3IvYmluL2VudiBub2RlXG5pbXBvcnQgKiBhcyBjZGsgZnJvbSAnYXdzLWNkay1saWInO1xuaW1wb3J0IHsgVGFrSW5mcmFTdGFjayB9IGZyb20gJy4uL2xpYi90YWstaW5mcmEtc3RhY2snO1xuaW1wb3J0IHsgYXBwbHlDb250ZXh0T3ZlcnJpZGVzIH0gZnJvbSAnLi4vbGliL3V0aWxzL2NvbnRleHQtb3ZlcnJpZGVzJztcbmltcG9ydCB7IERFRkFVTFRfQVdTX1JFR0lPTiB9IGZyb20gJy4uL2xpYi91dGlscy9jb25zdGFudHMnO1xuaW1wb3J0IHsgZ2VuZXJhdGVTdGFuZGFyZFRhZ3MgfSBmcm9tICcuLi9saWIvdXRpbHMvdGFnLWhlbHBlcnMnO1xuXG5jb25zdCBhcHAgPSBuZXcgY2RrLkFwcCgpO1xuXG4vLyBHZXQgZW52aXJvbm1lbnQgZnJvbSBjb250ZXh0IChkZWZhdWx0cyB0byBkZXYtdGVzdClcbmNvbnN0IGVudk5hbWUgPSBhcHAubm9kZS50cnlHZXRDb250ZXh0KCdlbnYnKSB8fCAnZGV2LXRlc3QnO1xuXG4vLyBHZXQgdGhlIGVudmlyb25tZW50IGNvbmZpZ3VyYXRpb24gZnJvbSBjb250ZXh0XG4vLyBDREsgYXV0b21hdGljYWxseSBoYW5kbGVzIGNvbnRleHQgb3ZlcnJpZGVzIHZpYSAtLWNvbnRleHQgZmxhZ1xuY29uc3QgZW52Q29uZmlnID0gYXBwLm5vZGUudHJ5R2V0Q29udGV4dChlbnZOYW1lKTtcbmNvbnN0IGRlZmF1bHRzID0gYXBwLm5vZGUudHJ5R2V0Q29udGV4dCgndGFrLWRlZmF1bHRzJyk7XG5cbmlmICghZW52Q29uZmlnKSB7XG4gIHRocm93IG5ldyBFcnJvcihgXG7inYwgRW52aXJvbm1lbnQgY29uZmlndXJhdGlvbiBmb3IgJyR7ZW52TmFtZX0nIG5vdCBmb3VuZCBpbiBjZGsuanNvblxuXG5Vc2FnZTpcbiAgbnB4IGNkayBkZXBsb3kgLS1jb250ZXh0IGVudj1kZXYtdGVzdFxuICBucHggY2RrIGRlcGxveSAtLWNvbnRleHQgZW52PXByb2RcblxuRXhwZWN0ZWQgY2RrLmpzb24gc3RydWN0dXJlOlxue1xuICBcImNvbnRleHRcIjoge1xuICAgIFwiZGV2LXRlc3RcIjogeyAuLi4gfSxcbiAgICBcInByb2RcIjogeyAuLi4gfVxuICB9XG59XG4gIGApO1xufVxuXG4vLyBBcHBseSBjb250ZXh0IG92ZXJyaWRlcyBmb3Igbm9uLXByZWZpeGVkIHBhcmFtZXRlcnNcbi8vIFRoaXMgc3VwcG9ydHMgZGlyZWN0IG92ZXJyaWRlcyB0aGF0IHdvcmsgZm9yIGFueSBlbnZpcm9ubWVudDpcbi8vIC0tY29udGV4dCB0YWtTZXJ2ZXJIb3N0bmFtZT1jdXN0b20tdGFrXG4vLyAtLWNvbnRleHQgYnJhbmRpbmc9Y3VzdG9tLWJyYW5kXG5jb25zdCBmaW5hbEVudkNvbmZpZyA9IGFwcGx5Q29udGV4dE92ZXJyaWRlcyhhcHAsIGVudkNvbmZpZyk7XG5cbi8vIENyZWF0ZSBzdGFjayBuYW1lXG5jb25zdCBzdGFja05hbWUgPSBgVEFLLSR7ZmluYWxFbnZDb25maWcuc3RhY2tOYW1lfS1UYWtJbmZyYWA7XG5cbi8vIENyZWF0ZSB0aGUgc3RhY2tcbmNvbnN0IHN0YWNrID0gbmV3IFRha0luZnJhU3RhY2soYXBwLCBzdGFja05hbWUsIHtcbiAgZW52aXJvbm1lbnQ6IGVudk5hbWUgYXMgJ3Byb2QnIHwgJ2Rldi10ZXN0JyxcbiAgZW52Q29uZmlnOiBmaW5hbEVudkNvbmZpZyxcbiAgZW52OiB7XG4gICAgYWNjb3VudDogcHJvY2Vzcy5lbnYuQ0RLX0RFRkFVTFRfQUNDT1VOVCxcbiAgICByZWdpb246IHByb2Nlc3MuZW52LkNES19ERUZBVUxUX1JFR0lPTiB8fCBkZWZhdWx0cz8ucmVnaW9uIHx8IERFRkFVTFRfQVdTX1JFR0lPTixcbiAgfSxcbiAgdGFnczogZ2VuZXJhdGVTdGFuZGFyZFRhZ3MoZmluYWxFbnZDb25maWcsIGVudk5hbWUgYXMgJ3Byb2QnIHwgJ2Rldi10ZXN0JywgZGVmYXVsdHMpXG59KTsiXX0=