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
      instanceCount: parseContextNumber(app.node.tryGetContext('instanceCount')) ?? baseConfig.database.instanceCount,
      engineVersion: app.node.tryGetContext('engineVersion') ?? baseConfig.database.engineVersion,
      allocatedStorage: parseContextNumber(app.node.tryGetContext('allocatedStorage')) ?? baseConfig.database.allocatedStorage,
      maxAllocatedStorage: parseContextNumber(app.node.tryGetContext('maxAllocatedStorage')) ?? baseConfig.database.maxAllocatedStorage,
      enablePerformanceInsights: parseContextBoolean(app.node.tryGetContext('enablePerformanceInsights')) ?? baseConfig.database.enablePerformanceInsights,
      monitoringInterval: parseContextNumber(app.node.tryGetContext('monitoringInterval')) ?? baseConfig.database.monitoringInterval,
      backupRetentionDays: parseContextNumber(app.node.tryGetContext('backupRetentionDays')) ?? baseConfig.database.backupRetentionDays,
      deleteProtection: parseContextBoolean(app.node.tryGetContext('deleteProtection')) ?? baseConfig.database.deleteProtection,
    },
    ecs: {
      ...baseConfig.ecs,
      taskCpu: parseContextNumber(app.node.tryGetContext('taskCpu')) ?? baseConfig.ecs.taskCpu,
      taskMemory: parseContextNumber(app.node.tryGetContext('taskMemory')) ?? baseConfig.ecs.taskMemory,
      desiredCount: parseContextNumber(app.node.tryGetContext('desiredCount')) ?? baseConfig.ecs.desiredCount,
      enableDetailedLogging: parseContextBoolean(app.node.tryGetContext('enableDetailedLogging')) ?? baseConfig.ecs.enableDetailedLogging,
      enableEcsExec: parseContextBoolean(app.node.tryGetContext('enableEcsExec')) ?? baseConfig.ecs.enableEcsExec,
    },
    takserver: {
      ...baseConfig.takserver,
      hostname: app.node.tryGetContext('takServerHostname') ?? baseConfig.takserver.hostname,
      servicename: app.node.tryGetContext('takServerServicename') ?? baseConfig.takserver.servicename,
      branding: app.node.tryGetContext('branding') ?? baseConfig.takserver.branding,
      version: app.node.tryGetContext('takServerVersion') ?? baseConfig.takserver.version,
      useS3TAKServerConfigFile: parseContextBoolean(app.node.tryGetContext('useS3TAKServerConfigFile')) ?? baseConfig.takserver.useS3TAKServerConfigFile,
      letsEncryptMode: app.node.tryGetContext('letsEncryptMode') ?? baseConfig.takserver.letsEncryptMode,
      letsEncryptEmail: app.node.tryGetContext('letsEncryptEmail') ?? baseConfig.takserver.letsEncryptEmail,
      enableFederation: parseContextBoolean(app.node.tryGetContext('enableFederation')) ?? baseConfig.takserver.enableFederation,
      enableCloudWatchMetrics: parseContextBoolean(app.node.tryGetContext('enableCloudWatchMetrics')) ?? baseConfig.takserver.enableCloudWatchMetrics,
    },
    ecr: {
      ...baseConfig.ecr,
      imageRetentionCount: parseContextNumber(app.node.tryGetContext('imageRetentionCount')) ?? baseConfig.ecr.imageRetentionCount,
      scanOnPush: parseContextBoolean(app.node.tryGetContext('scanOnPush')) ?? baseConfig.ecr.scanOnPush,
    },
    general: {
      ...baseConfig.general,
      removalPolicy: app.node.tryGetContext('removalPolicy') || baseConfig.general.removalPolicy,
      enableDetailedLogging: parseContextBoolean(app.node.tryGetContext('enableDetailedLogging')) ?? baseConfig.general.enableDetailedLogging,
      enableContainerInsights: parseContextBoolean(app.node.tryGetContext('enableContainerInsights')) ?? baseConfig.general.enableContainerInsights,
    },
    docker: {
      ...baseConfig.docker,
      takImageTag: app.node.tryGetContext('takImageTag') ?? baseConfig.docker?.takImageTag,
    },
  };
}

/**
 * Parse context value to number, handling string inputs from CLI
 */
function parseContextNumber(value: any): number | undefined {
  if (value === undefined || value === null) return undefined;
  const parsed = typeof value === 'string' ? parseInt(value, 10) : value;
  return isNaN(parsed) ? undefined : parsed;
}

/**
 * Parse context value to boolean, handling string inputs from CLI
 */
function parseContextBoolean(value: any): boolean | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === 'boolean') return value;
  if (typeof value === 'string') {
    return value.toLowerCase() === 'true';
  }
  return undefined;
}