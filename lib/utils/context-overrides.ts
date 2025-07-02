/**
 * Dynamic context override utilities
 * Simplified flat parameter system for command-line context overrides
 */

import * as cdk from 'aws-cdk-lib';
import { ContextEnvironmentConfig } from '../stack-config';

export function applyContextOverrides(
  app: cdk.App, 
  baseConfig: ContextEnvironmentConfig
): ContextEnvironmentConfig {
  const topLevelOverrides = {
    stackName: app.node.tryGetContext('stackName'),
  };

  return {
    ...baseConfig,
    ...Object.fromEntries(Object.entries(topLevelOverrides).filter(([_, v]) => v !== undefined)),
    database: {
      ...baseConfig.database,
      instanceClass: app.node.tryGetContext('instanceClass') ?? baseConfig.database.instanceClass,
      instanceCount: app.node.tryGetContext('instanceCount') ?? baseConfig.database.instanceCount,
      engineVersion: app.node.tryGetContext('engineVersion') ?? baseConfig.database.engineVersion,
      allocatedStorage: app.node.tryGetContext('allocatedStorage') ?? baseConfig.database.allocatedStorage,
      maxAllocatedStorage: app.node.tryGetContext('maxAllocatedStorage') ?? baseConfig.database.maxAllocatedStorage,
      enablePerformanceInsights: app.node.tryGetContext('enablePerformanceInsights') ?? baseConfig.database.enablePerformanceInsights,
      monitoringInterval: app.node.tryGetContext('monitoringInterval') ?? baseConfig.database.monitoringInterval,
      backupRetentionDays: app.node.tryGetContext('backupRetentionDays') ?? baseConfig.database.backupRetentionDays,
      deleteProtection: app.node.tryGetContext('deleteProtection') ?? baseConfig.database.deleteProtection,
    },
    ecs: {
      ...baseConfig.ecs,
      taskCpu: app.node.tryGetContext('taskCpu') ?? baseConfig.ecs.taskCpu,
      taskMemory: app.node.tryGetContext('taskMemory') ?? baseConfig.ecs.taskMemory,
      desiredCount: app.node.tryGetContext('desiredCount') ?? baseConfig.ecs.desiredCount,
      enableDetailedLogging: app.node.tryGetContext('enableDetailedLogging') ?? baseConfig.ecs.enableDetailedLogging,
      enableEcsExec: app.node.tryGetContext('enableEcsExec') ?? baseConfig.ecs.enableEcsExec,
    },
    takserver: {
      ...baseConfig.takserver,
      hostname: app.node.tryGetContext('takServerHostname') ?? baseConfig.takserver.hostname,
      servicename: app.node.tryGetContext('takServerServicename') ?? baseConfig.takserver.servicename,
      branding: app.node.tryGetContext('branding') ?? baseConfig.takserver.branding,
      version: app.node.tryGetContext('takServerVersion') ?? baseConfig.takserver.version,
      useS3TAKServerConfigFile: app.node.tryGetContext('useS3TAKServerConfigFile') ?? baseConfig.takserver.useS3TAKServerConfigFile,
      letsEncryptMode: app.node.tryGetContext('letsEncryptMode') ?? baseConfig.takserver.letsEncryptMode,
      letsEncryptEmail: app.node.tryGetContext('letsEncryptEmail') ?? baseConfig.takserver.letsEncryptEmail,
      enableFederation: app.node.tryGetContext('enableFederation') ?? baseConfig.takserver.enableFederation,
      enableCloudWatchMetrics: app.node.tryGetContext('enableCloudWatchMetrics') ?? baseConfig.takserver.enableCloudWatchMetrics,
    },
    ecr: {
      ...baseConfig.ecr,
      imageRetentionCount: app.node.tryGetContext('imageRetentionCount') ?? baseConfig.ecr.imageRetentionCount,
      scanOnPush: app.node.tryGetContext('scanOnPush') ?? baseConfig.ecr.scanOnPush,
    },
    general: {
      ...baseConfig.general,
      removalPolicy: app.node.tryGetContext('removalPolicy') || baseConfig.general.removalPolicy,
      enableDetailedLogging: app.node.tryGetContext('enableDetailedLogging') ?? baseConfig.general.enableDetailedLogging,
      enableContainerInsights: app.node.tryGetContext('enableContainerInsights') ?? baseConfig.general.enableContainerInsights,
    },
    docker: {
      ...baseConfig.docker,
      takImageTag: app.node.tryGetContext('takImageTag') ?? baseConfig.docker?.takImageTag,
    },
  };
}