#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { TakInfraStack } from '../lib/tak-infra-stack';

const app = new cdk.App();

const env = app.node.tryGetContext('env') || 'dev-test';
const config = app.node.tryGetContext(env);
const defaults = app.node.tryGetContext('tak-defaults');

if (!config) {
  throw new Error(`No configuration found for environment: ${env}`);
}

new TakInfraStack(app, `TAK-${config.stackName}-TakInfra`, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: defaults.region,
  },
  config,
  defaults,
});