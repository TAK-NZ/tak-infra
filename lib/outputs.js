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
exports.registerOutputs = registerOutputs;
/**
 * Centralized outputs management for the TAK Infrastructure stack
 */
const cdk = __importStar(require("aws-cdk-lib"));
function registerOutputs(params) {
    const { stack, stackName } = params;
    const outputs = [
        { key: 'DatabaseEndpoint', value: params.databaseEndpoint, description: 'RDS Aurora PostgreSQL cluster endpoint' },
        { key: 'DatabaseSecretArn', value: params.databaseSecretArn, description: 'RDS Aurora PostgreSQL master secret ARN' },
        { key: 'EfsId', value: params.efsId, description: 'EFS file system ID' },
        { key: 'EfsTakCertsAccessPoint', value: params.efsTakCertsAccessPointId, description: 'EFS TAK certs access point ID' },
        { key: 'EfsLetsEncryptAccessPoint', value: params.efsLetsEncryptAccessPointId, description: 'EFS Let\'s Encrypt access point ID' },
        { key: 'TakServerNlbDns', value: params.takServerNlbDns, description: 'TAK Server Network Load Balancer DNS name' },
        { key: 'TakServerUrl', value: params.takServerUrl, description: 'TAK Server application URL' },
        { key: 'TakServerApiUrl', value: params.takServerApiUrl, description: 'TAK Server API URL' },
    ];
    outputs.forEach(({ key, value, description }) => {
        new cdk.CfnOutput(stack, `${key}Output`, {
            value,
            description,
            exportName: `${stackName}-${key}`,
        });
    });
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoib3V0cHV0cy5qcyIsInNvdXJjZVJvb3QiOiIiLCJzb3VyY2VzIjpbIm91dHB1dHMudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6Ijs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7OztBQWtCQSwwQ0FxQkM7QUF2Q0Q7O0dBRUc7QUFDSCxpREFBbUM7QUFlbkMsU0FBZ0IsZUFBZSxDQUFDLE1BQW9CO0lBQ2xELE1BQU0sRUFBRSxLQUFLLEVBQUUsU0FBUyxFQUFFLEdBQUcsTUFBTSxDQUFDO0lBRXBDLE1BQU0sT0FBTyxHQUFHO1FBQ2QsRUFBRSxHQUFHLEVBQUUsa0JBQWtCLEVBQUUsS0FBSyxFQUFFLE1BQU0sQ0FBQyxnQkFBZ0IsRUFBRSxXQUFXLEVBQUUsd0NBQXdDLEVBQUU7UUFDbEgsRUFBRSxHQUFHLEVBQUUsbUJBQW1CLEVBQUUsS0FBSyxFQUFFLE1BQU0sQ0FBQyxpQkFBaUIsRUFBRSxXQUFXLEVBQUUseUNBQXlDLEVBQUU7UUFDckgsRUFBRSxHQUFHLEVBQUUsT0FBTyxFQUFFLEtBQUssRUFBRSxNQUFNLENBQUMsS0FBSyxFQUFFLFdBQVcsRUFBRSxvQkFBb0IsRUFBRTtRQUN4RSxFQUFFLEdBQUcsRUFBRSx3QkFBd0IsRUFBRSxLQUFLLEVBQUUsTUFBTSxDQUFDLHdCQUF3QixFQUFFLFdBQVcsRUFBRSwrQkFBK0IsRUFBRTtRQUN2SCxFQUFFLEdBQUcsRUFBRSwyQkFBMkIsRUFBRSxLQUFLLEVBQUUsTUFBTSxDQUFDLDJCQUEyQixFQUFFLFdBQVcsRUFBRSxvQ0FBb0MsRUFBRTtRQUNsSSxFQUFFLEdBQUcsRUFBRSxpQkFBaUIsRUFBRSxLQUFLLEVBQUUsTUFBTSxDQUFDLGVBQWUsRUFBRSxXQUFXLEVBQUUsMkNBQTJDLEVBQUU7UUFDbkgsRUFBRSxHQUFHLEVBQUUsY0FBYyxFQUFFLEtBQUssRUFBRSxNQUFNLENBQUMsWUFBWSxFQUFFLFdBQVcsRUFBRSw0QkFBNEIsRUFBRTtRQUM5RixFQUFFLEdBQUcsRUFBRSxpQkFBaUIsRUFBRSxLQUFLLEVBQUUsTUFBTSxDQUFDLGVBQWUsRUFBRSxXQUFXLEVBQUUsb0JBQW9CLEVBQUU7S0FDN0YsQ0FBQztJQUVGLE9BQU8sQ0FBQyxPQUFPLENBQUMsQ0FBQyxFQUFFLEdBQUcsRUFBRSxLQUFLLEVBQUUsV0FBVyxFQUFFLEVBQUUsRUFBRTtRQUM5QyxJQUFJLEdBQUcsQ0FBQyxTQUFTLENBQUMsS0FBSyxFQUFFLEdBQUcsR0FBRyxRQUFRLEVBQUU7WUFDdkMsS0FBSztZQUNMLFdBQVc7WUFDWCxVQUFVLEVBQUUsR0FBRyxTQUFTLElBQUksR0FBRyxFQUFFO1NBQ2xDLENBQUMsQ0FBQztJQUNMLENBQUMsQ0FBQyxDQUFDO0FBQ0wsQ0FBQyIsInNvdXJjZXNDb250ZW50IjpbIi8qKlxuICogQ2VudHJhbGl6ZWQgb3V0cHV0cyBtYW5hZ2VtZW50IGZvciB0aGUgVEFLIEluZnJhc3RydWN0dXJlIHN0YWNrXG4gKi9cbmltcG9ydCAqIGFzIGNkayBmcm9tICdhd3MtY2RrLWxpYic7XG5cbmV4cG9ydCBpbnRlcmZhY2UgT3V0cHV0UGFyYW1zIHtcbiAgc3RhY2s6IGNkay5TdGFjaztcbiAgc3RhY2tOYW1lOiBzdHJpbmc7XG4gIGRhdGFiYXNlRW5kcG9pbnQ6IHN0cmluZztcbiAgZGF0YWJhc2VTZWNyZXRBcm46IHN0cmluZztcbiAgZWZzSWQ6IHN0cmluZztcbiAgZWZzVGFrQ2VydHNBY2Nlc3NQb2ludElkOiBzdHJpbmc7XG4gIGVmc0xldHNFbmNyeXB0QWNjZXNzUG9pbnRJZDogc3RyaW5nO1xuICB0YWtTZXJ2ZXJObGJEbnM6IHN0cmluZztcbiAgdGFrU2VydmVyVXJsOiBzdHJpbmc7XG4gIHRha1NlcnZlckFwaVVybDogc3RyaW5nO1xufVxuXG5leHBvcnQgZnVuY3Rpb24gcmVnaXN0ZXJPdXRwdXRzKHBhcmFtczogT3V0cHV0UGFyYW1zKTogdm9pZCB7XG4gIGNvbnN0IHsgc3RhY2ssIHN0YWNrTmFtZSB9ID0gcGFyYW1zO1xuICBcbiAgY29uc3Qgb3V0cHV0cyA9IFtcbiAgICB7IGtleTogJ0RhdGFiYXNlRW5kcG9pbnQnLCB2YWx1ZTogcGFyYW1zLmRhdGFiYXNlRW5kcG9pbnQsIGRlc2NyaXB0aW9uOiAnUkRTIEF1cm9yYSBQb3N0Z3JlU1FMIGNsdXN0ZXIgZW5kcG9pbnQnIH0sXG4gICAgeyBrZXk6ICdEYXRhYmFzZVNlY3JldEFybicsIHZhbHVlOiBwYXJhbXMuZGF0YWJhc2VTZWNyZXRBcm4sIGRlc2NyaXB0aW9uOiAnUkRTIEF1cm9yYSBQb3N0Z3JlU1FMIG1hc3RlciBzZWNyZXQgQVJOJyB9LFxuICAgIHsga2V5OiAnRWZzSWQnLCB2YWx1ZTogcGFyYW1zLmVmc0lkLCBkZXNjcmlwdGlvbjogJ0VGUyBmaWxlIHN5c3RlbSBJRCcgfSxcbiAgICB7IGtleTogJ0Vmc1Rha0NlcnRzQWNjZXNzUG9pbnQnLCB2YWx1ZTogcGFyYW1zLmVmc1Rha0NlcnRzQWNjZXNzUG9pbnRJZCwgZGVzY3JpcHRpb246ICdFRlMgVEFLIGNlcnRzIGFjY2VzcyBwb2ludCBJRCcgfSxcbiAgICB7IGtleTogJ0Vmc0xldHNFbmNyeXB0QWNjZXNzUG9pbnQnLCB2YWx1ZTogcGFyYW1zLmVmc0xldHNFbmNyeXB0QWNjZXNzUG9pbnRJZCwgZGVzY3JpcHRpb246ICdFRlMgTGV0XFwncyBFbmNyeXB0IGFjY2VzcyBwb2ludCBJRCcgfSxcbiAgICB7IGtleTogJ1Rha1NlcnZlck5sYkRucycsIHZhbHVlOiBwYXJhbXMudGFrU2VydmVyTmxiRG5zLCBkZXNjcmlwdGlvbjogJ1RBSyBTZXJ2ZXIgTmV0d29yayBMb2FkIEJhbGFuY2VyIEROUyBuYW1lJyB9LFxuICAgIHsga2V5OiAnVGFrU2VydmVyVXJsJywgdmFsdWU6IHBhcmFtcy50YWtTZXJ2ZXJVcmwsIGRlc2NyaXB0aW9uOiAnVEFLIFNlcnZlciBhcHBsaWNhdGlvbiBVUkwnIH0sXG4gICAgeyBrZXk6ICdUYWtTZXJ2ZXJBcGlVcmwnLCB2YWx1ZTogcGFyYW1zLnRha1NlcnZlckFwaVVybCwgZGVzY3JpcHRpb246ICdUQUsgU2VydmVyIEFQSSBVUkwnIH0sXG4gIF07XG5cbiAgb3V0cHV0cy5mb3JFYWNoKCh7IGtleSwgdmFsdWUsIGRlc2NyaXB0aW9uIH0pID0+IHtcbiAgICBuZXcgY2RrLkNmbk91dHB1dChzdGFjaywgYCR7a2V5fU91dHB1dGAsIHtcbiAgICAgIHZhbHVlLFxuICAgICAgZGVzY3JpcHRpb24sXG4gICAgICBleHBvcnROYW1lOiBgJHtzdGFja05hbWV9LSR7a2V5fWAsXG4gICAgfSk7XG4gIH0pO1xufSJdfQ==