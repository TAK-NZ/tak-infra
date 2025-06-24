/**
 * Configuration interface for TakInfra stack template
 * This makes the stack reusable across different projects and environments
 */
/**
 * Context-based configuration interface matching cdk.context.json structure
 * This is used directly by the stack without complex transformations
 */
export interface ContextEnvironmentConfig {
    stackName: string;
    database: {
        instanceClass: string;
        instanceCount: number;
        engineVersion?: string;
        backupRetentionDays: number;
        deleteProtection: boolean;
    };
    ecs: {
        taskCpu: number;
        taskMemory: number;
        desiredCount: number;
        enableEcsExec?: boolean;
    };
    takserver: {
        hostname: string;
        servicename: string;
        branding: string;
        version: string;
        useS3Config: boolean;
    };
    general: {
        removalPolicy: string;
        enableDetailedLogging: boolean;
    };
}
