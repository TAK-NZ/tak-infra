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
    allocatedStorage: number;
    maxAllocatedStorage: number;
    enablePerformanceInsights: boolean;
    monitoringInterval: number;
    backupRetentionDays: number;
    deleteProtection: boolean;
    enableCloudWatchLogs?: boolean;
  };
  ecs: {
    taskCpu: number;
    taskMemory: number;
    desiredCount: number;
    enableDetailedLogging: boolean;
    enableEcsExec?: boolean;
  };
  takserver: {
    hostname: string;
    servicename: string;
    branding: string;
    version: string;
    buildRevision?: number;
    useS3TAKServerConfigFile: boolean;
    letsEncryptMode?: string;
    letsEncryptEmail?: string;
    enableFederation?: boolean;
    enableCloudWatchMetrics?: boolean;
    ldapGroupPrefix?: string;
  };
  ecr: {
    imageRetentionCount: number;
    scanOnPush: boolean;
  };
  general: {
    removalPolicy: string;
    enableDetailedLogging: boolean;
    enableContainerInsights: boolean;
  };
  docker?: {
    takImageTag?: string;
  };
  webtak?: {
    enableOidc?: boolean;
    providerName?: string;
    applicationName?: string;
    applicationSlug?: string;
    openInNewTab?: boolean;
    authenticationFlowName?: string;
    authorizationFlowName?: string;
    invalidationFlowName?: string;
    groupName?: string;
    description?: string;
    iconPath?: string;
    signingKeyName?: string;
    useTakServerLoginPage?: boolean;
  };
}