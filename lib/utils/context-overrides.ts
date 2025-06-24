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
      backupRetentionDays: app.node.tryGetContext('backupRetentionDays') ?? baseConfig.database.backupRetentionDays,
      deleteProtection: app.node.tryGetContext('deleteProtection') ?? baseConfig.database.deleteProtection,
    },
    ecs: {
      ...baseConfig.ecs,
      taskCpu: app.node.tryGetContext('taskCpu') ?? baseConfig.ecs.taskCpu,
      taskMemory: app.node.tryGetContext('taskMemory') ?? baseConfig.ecs.taskMemory,
      desiredCount: app.node.tryGetContext('desiredCount') ?? baseConfig.ecs.desiredCount,
    },
    takserver: {
      ...baseConfig.takserver,
      hostname: app.node.tryGetContext('takServerHostname') ?? baseConfig.takserver.hostname,
      branding: app.node.tryGetContext('branding') ?? baseConfig.takserver.branding,
      version: app.node.tryGetContext('takServerVersion') ?? baseConfig.takserver.version,
      useS3Config: app.node.tryGetContext('useS3Config') ?? baseConfig.takserver.useS3Config,
    },
    general: {
      ...baseConfig.general,
      removalPolicy: app.node.tryGetContext('removalPolicy') || baseConfig.general.removalPolicy,
      enableDetailedLogging: app.node.tryGetContext('enableDetailedLogging') ?? baseConfig.general.enableDetailedLogging,
    },
  };
}