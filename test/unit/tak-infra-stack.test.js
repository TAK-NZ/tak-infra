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
    const config = {
        stackName: 'Test',
        database: { instanceClass: 'db.serverless' },
        ecs: { taskCpu: 1024, taskMemory: 2048 },
        takserver: { hostname: 'tak', branding: 'generic' },
        general: { removalPolicy: 'DESTROY' }
    };
    const defaults = { project: 'TAK.NZ', component: 'TakInfra', region: 'ap-southeast-2' };
    const stack = new tak_infra_stack_1.TakInfraStack(app, 'TestTakInfraStack', { config, defaults });
    const template = assertions_1.Template.fromStack(stack);
    // Basic test to ensure stack synthesizes without errors
    expect(template).toBeDefined();
});
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoidGFrLWluZnJhLXN0YWNrLnRlc3QuanMiLCJzb3VyY2VSb290IjoiIiwic291cmNlcyI6WyJ0YWstaW5mcmEtc3RhY2sudGVzdC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBQUEsaURBQW1DO0FBQ25DLHVEQUFrRDtBQUNsRCwrREFBMEQ7QUFFMUQsSUFBSSxDQUFDLG9DQUFvQyxFQUFFLEdBQUcsRUFBRTtJQUM5QyxNQUFNLEdBQUcsR0FBRyxJQUFJLEdBQUcsQ0FBQyxHQUFHLEVBQUUsQ0FBQztJQUMxQixNQUFNLE1BQU0sR0FBRztRQUNiLFNBQVMsRUFBRSxNQUFNO1FBQ2pCLFFBQVEsRUFBRSxFQUFFLGFBQWEsRUFBRSxlQUFlLEVBQUU7UUFDNUMsR0FBRyxFQUFFLEVBQUUsT0FBTyxFQUFFLElBQUksRUFBRSxVQUFVLEVBQUUsSUFBSSxFQUFFO1FBQ3hDLFNBQVMsRUFBRSxFQUFFLFFBQVEsRUFBRSxLQUFLLEVBQUUsUUFBUSxFQUFFLFNBQVMsRUFBRTtRQUNuRCxPQUFPLEVBQUUsRUFBRSxhQUFhLEVBQUUsU0FBUyxFQUFFO0tBQ3RDLENBQUM7SUFDRixNQUFNLFFBQVEsR0FBRyxFQUFFLE9BQU8sRUFBRSxRQUFRLEVBQUUsU0FBUyxFQUFFLFVBQVUsRUFBRSxNQUFNLEVBQUUsZ0JBQWdCLEVBQUUsQ0FBQztJQUV4RixNQUFNLEtBQUssR0FBRyxJQUFJLCtCQUFhLENBQUMsR0FBRyxFQUFFLG1CQUFtQixFQUFFLEVBQUUsTUFBTSxFQUFFLFFBQVEsRUFBRSxDQUFDLENBQUM7SUFDaEYsTUFBTSxRQUFRLEdBQUcscUJBQVEsQ0FBQyxTQUFTLENBQUMsS0FBSyxDQUFDLENBQUM7SUFFM0Msd0RBQXdEO0lBQ3hELE1BQU0sQ0FBQyxRQUFRLENBQUMsQ0FBQyxXQUFXLEVBQUUsQ0FBQztBQUNqQyxDQUFDLENBQUMsQ0FBQyIsInNvdXJjZXNDb250ZW50IjpbImltcG9ydCAqIGFzIGNkayBmcm9tICdhd3MtY2RrLWxpYic7XG5pbXBvcnQgeyBUZW1wbGF0ZSB9IGZyb20gJ2F3cy1jZGstbGliL2Fzc2VydGlvbnMnO1xuaW1wb3J0IHsgVGFrSW5mcmFTdGFjayB9IGZyb20gJy4uLy4uL2xpYi90YWstaW5mcmEtc3RhY2snO1xuXG50ZXN0KCdUYWtJbmZyYVN0YWNrIGNyZWF0ZXMgc3VjY2Vzc2Z1bGx5JywgKCkgPT4ge1xuICBjb25zdCBhcHAgPSBuZXcgY2RrLkFwcCgpO1xuICBjb25zdCBjb25maWcgPSB7XG4gICAgc3RhY2tOYW1lOiAnVGVzdCcsXG4gICAgZGF0YWJhc2U6IHsgaW5zdGFuY2VDbGFzczogJ2RiLnNlcnZlcmxlc3MnIH0sXG4gICAgZWNzOiB7IHRhc2tDcHU6IDEwMjQsIHRhc2tNZW1vcnk6IDIwNDggfSxcbiAgICB0YWtzZXJ2ZXI6IHsgaG9zdG5hbWU6ICd0YWsnLCBicmFuZGluZzogJ2dlbmVyaWMnIH0sXG4gICAgZ2VuZXJhbDogeyByZW1vdmFsUG9saWN5OiAnREVTVFJPWScgfVxuICB9O1xuICBjb25zdCBkZWZhdWx0cyA9IHsgcHJvamVjdDogJ1RBSy5OWicsIGNvbXBvbmVudDogJ1Rha0luZnJhJywgcmVnaW9uOiAnYXAtc291dGhlYXN0LTInIH07XG4gIFxuICBjb25zdCBzdGFjayA9IG5ldyBUYWtJbmZyYVN0YWNrKGFwcCwgJ1Rlc3RUYWtJbmZyYVN0YWNrJywgeyBjb25maWcsIGRlZmF1bHRzIH0pO1xuICBjb25zdCB0ZW1wbGF0ZSA9IFRlbXBsYXRlLmZyb21TdGFjayhzdGFjayk7XG4gIFxuICAvLyBCYXNpYyB0ZXN0IHRvIGVuc3VyZSBzdGFjayBzeW50aGVzaXplcyB3aXRob3V0IGVycm9yc1xuICBleHBlY3QodGVtcGxhdGUpLnRvQmVEZWZpbmVkKCk7XG59KTsiXX0=