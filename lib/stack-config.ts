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
    serverlessV2MinCapacity?: number;
    serverlessV2MaxCapacity?: number;
    enablePerformanceInsights: boolean;
    monitoringInterval: number;
    backupRetentionDays: number;
    deleteProtection: boolean;
    enableCloudWatchLogs?: boolean;
    /**
     * Aurora storage type. Unset leaves the cluster's storage type untouched; `true` selects
     * Aurora I/O-Optimized (no per-request I/O charge, higher instance and storage price);
     * `false` selects Aurora Standard. AWS allows moving from I/O-Optimized back to Standard
     * only once every 30 days.
     */
    ioOptimized?: boolean;
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
  /**
   * TAK-GPT Bedrock knowledge bases to create (S3 Vectors storage). Each name is also the folder
   * the source documents are read from: `bedrock-kb/<name>/` in the TAK Images bucket.
   * Unset or empty creates none.
   */
  bedrock?: {
    knowledgeBases?: string[];
  };
  webtak?: {
    enabled?: boolean;
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
    hideAuthentikApp?: boolean;
  };
}