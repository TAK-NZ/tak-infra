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
require("source-map-support/register");
const cdk = __importStar(require("aws-cdk-lib"));
const tak_infra_stack_1 = require("../lib/tak-infra-stack");
const app = new cdk.App();
const env = app.node.tryGetContext('env') || 'dev-test';
const config = app.node.tryGetContext(env);
const defaults = app.node.tryGetContext('tak-defaults');
if (!config) {
    throw new Error(`No configuration found for environment: ${env}`);
}
new tak_infra_stack_1.TakInfraStack(app, `TAK-${config.stackName}-TakInfra`, {
    env: {
        account: process.env.CDK_DEFAULT_ACCOUNT,
        region: defaults.region,
    },
    config,
    defaults,
});
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiY2RrLmpzIiwic291cmNlUm9vdCI6IiIsInNvdXJjZXMiOlsiY2RrLnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiI7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBQ0EsdUNBQXFDO0FBQ3JDLGlEQUFtQztBQUNuQyw0REFBdUQ7QUFFdkQsTUFBTSxHQUFHLEdBQUcsSUFBSSxHQUFHLENBQUMsR0FBRyxFQUFFLENBQUM7QUFFMUIsTUFBTSxHQUFHLEdBQUcsR0FBRyxDQUFDLElBQUksQ0FBQyxhQUFhLENBQUMsS0FBSyxDQUFDLElBQUksVUFBVSxDQUFDO0FBQ3hELE1BQU0sTUFBTSxHQUFHLEdBQUcsQ0FBQyxJQUFJLENBQUMsYUFBYSxDQUFDLEdBQUcsQ0FBQyxDQUFDO0FBQzNDLE1BQU0sUUFBUSxHQUFHLEdBQUcsQ0FBQyxJQUFJLENBQUMsYUFBYSxDQUFDLGNBQWMsQ0FBQyxDQUFDO0FBRXhELElBQUksQ0FBQyxNQUFNLEVBQUUsQ0FBQztJQUNaLE1BQU0sSUFBSSxLQUFLLENBQUMsMkNBQTJDLEdBQUcsRUFBRSxDQUFDLENBQUM7QUFDcEUsQ0FBQztBQUVELElBQUksK0JBQWEsQ0FBQyxHQUFHLEVBQUUsT0FBTyxNQUFNLENBQUMsU0FBUyxXQUFXLEVBQUU7SUFDekQsR0FBRyxFQUFFO1FBQ0gsT0FBTyxFQUFFLE9BQU8sQ0FBQyxHQUFHLENBQUMsbUJBQW1CO1FBQ3hDLE1BQU0sRUFBRSxRQUFRLENBQUMsTUFBTTtLQUN4QjtJQUNELE1BQU07SUFDTixRQUFRO0NBQ1QsQ0FBQyxDQUFDIiwic291cmNlc0NvbnRlbnQiOlsiIyEvdXNyL2Jpbi9lbnYgbm9kZVxuaW1wb3J0ICdzb3VyY2UtbWFwLXN1cHBvcnQvcmVnaXN0ZXInO1xuaW1wb3J0ICogYXMgY2RrIGZyb20gJ2F3cy1jZGstbGliJztcbmltcG9ydCB7IFRha0luZnJhU3RhY2sgfSBmcm9tICcuLi9saWIvdGFrLWluZnJhLXN0YWNrJztcblxuY29uc3QgYXBwID0gbmV3IGNkay5BcHAoKTtcblxuY29uc3QgZW52ID0gYXBwLm5vZGUudHJ5R2V0Q29udGV4dCgnZW52JykgfHwgJ2Rldi10ZXN0JztcbmNvbnN0IGNvbmZpZyA9IGFwcC5ub2RlLnRyeUdldENvbnRleHQoZW52KTtcbmNvbnN0IGRlZmF1bHRzID0gYXBwLm5vZGUudHJ5R2V0Q29udGV4dCgndGFrLWRlZmF1bHRzJyk7XG5cbmlmICghY29uZmlnKSB7XG4gIHRocm93IG5ldyBFcnJvcihgTm8gY29uZmlndXJhdGlvbiBmb3VuZCBmb3IgZW52aXJvbm1lbnQ6ICR7ZW52fWApO1xufVxuXG5uZXcgVGFrSW5mcmFTdGFjayhhcHAsIGBUQUstJHtjb25maWcuc3RhY2tOYW1lfS1UYWtJbmZyYWAsIHtcbiAgZW52OiB7XG4gICAgYWNjb3VudDogcHJvY2Vzcy5lbnYuQ0RLX0RFRkFVTFRfQUNDT1VOVCxcbiAgICByZWdpb246IGRlZmF1bHRzLnJlZ2lvbixcbiAgfSxcbiAgY29uZmlnLFxuICBkZWZhdWx0cyxcbn0pOyJdfQ==