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
  /**
   * PKI settings for new stacks (#136, #171, #189).
   */
  pki?: {
    /**
     * Root CA and Intermediate CA signing keys in AWS KMS, and the first-boot PKI. `enabled` is true in the
     * `dev-test` and `prod` profiles of cdk.json. Unset or `enabled: false` keeps the old behaviour (CA keys as
     * files on EFS, no rotation) and creates nothing: set it with `--context pkiKmsCaEnabled=false` for a stack
     * that must stay on the old PKI.
     */
    kmsCa?: {
      enabled: boolean;
      /**
       * Environment label in CA names and aliases, e.g. `Try` -> `TAK.NZ Try Root CA 01`. Defaults to the stack
       * name (which is unique per account and region, like the aliases). Set it for a stack whose label is
       * not its stack name, and keep it on every deploy: it is part of the CA names.
       */
      environmentLabel: string;
      /**
       * Root CA key generations to create. Default `[1, 2]`: the next generation exists from the start as the spare
       * for the next rotation. After a rotation uses the spare, add the next number (the orchestrator raises
       * `RotationSpareKeyMissing` years before it is needed).
       */
      rootCaNumbers?: number[];
      /** Intermediate CA key generations to create. Default `[1, 2]` (see `rootCaNumbers`). */
      intermediateCaNumbers?: number[];
      /** Email address that receives the alert and critical certificate messages (including every Root CA signature). */
      alertEmail?: string;
      /** Email address that receives the informational certificate messages (a rotation step happened). */
      infoEmail?: string;
      /** Validity of the first-boot PKI, in days (#189). Defaults: 7300 / 3650 / 1095 / 365 / 365. */
      validity?: {
        rootDays?: number;
        intermediateDays?: number;
        enrollmentCaDays?: number;
        serverCertDays?: number;
        adminCertDays?: number;
        /** Rotate the server certificate when this many days or fewer are left (#131). Default 60. */
        serverCertRenewDays?: number;
        /** Rotate the admin certificate when this many days or fewer are left (#132). Default 60. */
        adminCertRenewDays?: number;
        /** Days until the copies of the previous admin key are deleted after a rotation (#132). Default 7. */
        adminCertGraceDays?: number;
      };
      /** Rotation orchestrator settings (#171). */
      rotation?: {
        /** Validity of client certificates in days: the `validityDays` of TAK Server's CA config. Default 365. */
        clientCertDays?: number;
        /** Safety buffer B in days; the overlap window W is `clientCertDays + bufferDays`. Default 90. */
        bufferDays?: number;
        /** The Enrollment CA is replaced when it is this many days old. Default 365. */
        enrollmentCaRotationDays?: number;
        /** Steps that wait for `pki-rotate.sh approve <scenario> <step>` before they run. Default: the steps that cannot be undone, `cut` and `retire`. */
        requireApproval?: string[];
      };
      /** PKCS#12 profile of the user-facing p12 files: `compat3des` (default) or `aes256` (#133). */
      p12Profile?: 'compat3des' | 'aes256';
    };
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