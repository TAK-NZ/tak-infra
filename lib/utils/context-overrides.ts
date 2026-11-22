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
      enableCloudWatchLogs: parseContextBoolean(app.node.tryGetContext('enableCloudWatchLogs')) ?? baseConfig.database.enableCloudWatchLogs,
      ioOptimized: parseContextBoolean(app.node.tryGetContext('ioOptimized')) ?? baseConfig.database.ioOptimized,
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
      hostname: app.node.tryGetContext('hostname') ?? baseConfig.takserver.hostname,
      servicename: app.node.tryGetContext('servicename') ?? baseConfig.takserver.servicename,
      branding: app.node.tryGetContext('branding') ?? baseConfig.takserver.branding,
      version: app.node.tryGetContext('version') ?? baseConfig.takserver.version,
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
    bedrock: {
      ...baseConfig.bedrock,
      knowledgeBases: parseContextList(app.node.tryGetContext('bedrockKnowledgeBases')) ?? baseConfig.bedrock?.knowledgeBases,
    },
    pki: applyPkiOverrides(app, baseConfig.pki),
  };
}

/**
 * Root CA / Intermediate CA keys in KMS (#136). Stays undefined unless the config or the command
 * line mentions it, so stacks that do not use it are unchanged.
 */
function applyPkiOverrides(app: cdk.App, base: ContextEnvironmentConfig['pki']): ContextEnvironmentConfig['pki'] {
  const enabled = parseContextBoolean(app.node.tryGetContext('pkiKmsCaEnabled'));
  const environmentLabel = app.node.tryGetContext('pkiEnvironmentLabel');
  const rootCaNumbers = parseContextNumberList(app.node.tryGetContext('pkiRootCaNumbers'));
  const intermediateCaNumbers = parseContextNumberList(app.node.tryGetContext('pkiIntermediateCaNumbers'));
  const alertEmail = app.node.tryGetContext('pkiAlertEmail');
  const infoEmail = app.node.tryGetContext('pkiInfoEmail');
  const p12Profile = app.node.tryGetContext('pkiP12Profile');
  const rotationDays = {
    clientCertDays: parseContextNumber(app.node.tryGetContext('pkiClientCertDays')),
    bufferDays: parseContextNumber(app.node.tryGetContext('pkiRotationBufferDays')),
    enrollmentCaRotationDays: parseContextNumber(app.node.tryGetContext('pkiEnrollmentCaRotationDays')),
  };
  const rotationApproval = parseContextList(app.node.tryGetContext('pkiRotationRequireApproval'));
  const rotationOverridden = Object.values(rotationDays).some(v => v !== undefined) || rotationApproval !== undefined;
  const days = {
    rootDays: parseContextNumber(app.node.tryGetContext('pkiRootDays')),
    intermediateDays: parseContextNumber(app.node.tryGetContext('pkiIntermediateDays')),
    enrollmentCaDays: parseContextNumber(app.node.tryGetContext('pkiEnrollmentCaDays')),
    serverCertDays: parseContextNumber(app.node.tryGetContext('pkiServerCertDays')),
    adminCertDays: parseContextNumber(app.node.tryGetContext('pkiAdminCertDays')),
    serverCertRenewDays: parseContextNumber(app.node.tryGetContext('pkiServerCertRenewDays')),
    adminCertRenewDays: parseContextNumber(app.node.tryGetContext('pkiAdminCertRenewDays')),
    adminCertGraceDays: parseContextNumber(app.node.tryGetContext('pkiAdminCertGraceDays')),
  };
  const daysOverridden = Object.values(days).some(v => v !== undefined);
  const overridden = [enabled, environmentLabel, rootCaNumbers, intermediateCaNumbers, alertEmail, infoEmail, p12Profile].some(v => v !== undefined) || daysOverridden || rotationOverridden;
  if (!base?.kmsCa && !overridden) return base;
  const kmsCa = base?.kmsCa;
  const merged = {
    enabled: enabled ?? kmsCa?.enabled ?? false,
    environmentLabel: environmentLabel ?? kmsCa?.environmentLabel,
    rootCaNumbers: rootCaNumbers ?? kmsCa?.rootCaNumbers,
    intermediateCaNumbers: intermediateCaNumbers ?? kmsCa?.intermediateCaNumbers,
    alertEmail: alertEmail ?? kmsCa?.alertEmail,
    infoEmail: infoEmail ?? kmsCa?.infoEmail,
    p12Profile: p12Profile ?? kmsCa?.p12Profile,
    rotation: rotationOverridden || kmsCa?.rotation
      ? {
        ...kmsCa?.rotation,
        ...Object.fromEntries(Object.entries(rotationDays).filter(([, v]) => v !== undefined)),
        ...(rotationApproval !== undefined ? { requireApproval: rotationApproval } : {}),
      }
      : undefined,
    validity: daysOverridden || kmsCa?.validity
      ? { ...kmsCa?.validity, ...Object.fromEntries(Object.entries(days).filter(([, v]) => v !== undefined)) }
      : undefined,
  };
  if (merged.enabled && !merged.environmentLabel) {
    throw new Error('pki.kmsCa is enabled but has no environmentLabel (set pki.kmsCa.environmentLabel or --context pkiEnvironmentLabel=<label>)');
  }
  return { ...base, kmsCa: merged as NonNullable<ContextEnvironmentConfig['pki']>['kmsCa'] };
}

/**
 * Parse a comma-separated list of numbers (for example `1,2`). Anything that is not a number is
 * an error rather than silently dropped.
 */
function parseContextNumberList(value: any): number[] | undefined {
  const items = parseContextList(value);
  if (items === undefined) return undefined;
  return items.map(item => {
    const n = Number(item);
    if (!Number.isInteger(n)) throw new Error(`Invalid number '${item}' in context list '${value}'`);
    return n;
  });
}

/**
 * Parse a comma-separated context value (for example `nema-cdem,nzdf`) into a list.
 * An empty string is an explicit empty list, so a deployment can switch the list off.
 */
function parseContextList(value: any): string[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (Array.isArray(value)) return value.map(String);
  return String(value).split(',').map(v => v.trim()).filter(v => v.length > 0);
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
