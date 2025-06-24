import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { TakInfraConfig, TakDefaults } from './config/interfaces';
import { validateConfig, validateDefaults } from './config/validator';
import { applyTags } from './utils/tagging';
import { importBaseInfraResources } from './utils/imports';

export interface TakInfraStackProps extends cdk.StackProps {
  config: TakInfraConfig;
  defaults: TakDefaults;
}

export class TakInfraStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: TakInfraStackProps) {
    super(scope, id, props);

    const config = validateConfig(props.config);
    const defaults = validateDefaults(props.defaults);
    
    // Apply consistent tagging
    applyTags(this, defaults, config.stackName);
    
    // Import base infrastructure resources
    const baseResources = importBaseInfraResources(this, config.stackName);
    
    // TODO: Implement TAK infrastructure constructs in Phase 2
  }
}