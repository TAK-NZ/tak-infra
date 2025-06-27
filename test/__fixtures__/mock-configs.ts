/**
 * Reusable test configuration objects for TAK Infrastructure
 */
import type { ContextEnvironmentConfig } from '../../lib/stack-config';

export const MOCK_CONFIGS = {
  DEV_TEST: {
    stackName: 'DevTest',
    database: {
      instanceClass: 'db.serverless',
      instanceCount: 1,
      engineVersion: '17.4',
      allocatedStorage: 20,
      maxAllocatedStorage: 100,
      enablePerformanceInsights: false,
      monitoringInterval: 0,
      backupRetentionDays: 7,
      deleteProtection: false
    },
    ecs: {
      taskCpu: 1024,
      taskMemory: 2048,
      desiredCount: 1,
      enableDetailedLogging: true,
      enableEcsExec: true
    },
    takserver: {
      hostname: 'tak',
      servicename: 'ops',
      branding: 'generic',
      version: '5.4-RELEASE-19',
      useS3TAKServerConfigFile: false,
      letsEncryptMode: 'disabled',
      enableFederation: false,
      enableCloudWatchMetrics: true
    },
    ecr: {
      imageRetentionCount: 5,
      scanOnPush: false
    },
    general: {
      removalPolicy: 'DESTROY',
      enableDetailedLogging: true,
      enableContainerInsights: false
    }
  } as ContextEnvironmentConfig,

  PROD: {
    stackName: 'Prod',
    database: {
      instanceClass: 'db.t4g.large',
      instanceCount: 2,
      engineVersion: '17.4',
      allocatedStorage: 100,
      maxAllocatedStorage: 1000,
      enablePerformanceInsights: true,
      monitoringInterval: 60,
      backupRetentionDays: 30,
      deleteProtection: true
    },
    ecs: {
      taskCpu: 2048,
      taskMemory: 4096,
      desiredCount: 2,
      enableDetailedLogging: false,
      enableEcsExec: false
    },
    takserver: {
      hostname: 'tak',
      servicename: 'ops',
      branding: 'tak-nz',
      version: '5.4-RELEASE-19',
      useS3TAKServerConfigFile: true,
      letsEncryptMode: 'enabled',
      letsEncryptEmail: 'admin@prod.com',
      enableFederation: true,
      enableCloudWatchMetrics: true
    },
    ecr: {
      imageRetentionCount: 20,
      scanOnPush: true
    },
    general: {
      removalPolicy: 'RETAIN',
      enableDetailedLogging: false,
      enableContainerInsights: true
    }
  } as ContextEnvironmentConfig,

  SERVERLESS: {
    stackName: 'Serverless',
    database: {
      instanceClass: 'db.serverless',
      instanceCount: 1,
      engineVersion: '17.4',
      allocatedStorage: 20,
      maxAllocatedStorage: 100,
      enablePerformanceInsights: false,
      monitoringInterval: 0,
      backupRetentionDays: 1,
      deleteProtection: false
    },
    ecs: {
      taskCpu: 512,
      taskMemory: 1024,
      desiredCount: 1,
      enableDetailedLogging: true,
      enableEcsExec: true
    },
    takserver: {
      hostname: 'tak',
      servicename: 'ops',
      branding: 'generic',
      version: '5.4-RELEASE-19',
      useS3TAKServerConfigFile: false,
      enableFederation: false,
      enableCloudWatchMetrics: false
    },
    ecr: {
      imageRetentionCount: 5,
      scanOnPush: false
    },
    general: {
      removalPolicy: 'DESTROY',
      enableDetailedLogging: true,
      enableContainerInsights: false
    }
  } as ContextEnvironmentConfig
};