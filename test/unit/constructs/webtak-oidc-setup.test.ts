import * as cdk from 'aws-cdk-lib';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as kms from 'aws-cdk-lib/aws-kms';
import { Template } from 'aws-cdk-lib/assertions';
import { WebTakOidcSetup } from '../../../lib/constructs/webtak-oidc-setup';
import { ContextEnvironmentConfig } from '../../../lib/stack-config';

describe('WebTakOidcSetup', () => {
  let app: cdk.App;
  let stack: cdk.Stack;
  let mockStackConfig: ContextEnvironmentConfig;

  beforeEach(() => {
    app = new cdk.App();
    stack = new cdk.Stack(app, 'TestStack');
    
    mockStackConfig = {
      stackName: 'Test',
      database: {
        instanceClass: 'db.serverless',
        instanceCount: 1,
        allocatedStorage: 20,
        maxAllocatedStorage: 100,
        enablePerformanceInsights: false,
        monitoringInterval: 0,
        backupRetentionDays: 7,
        deleteProtection: false,
      },
      ecs: {
        taskCpu: 2048,
        taskMemory: 4096,
        desiredCount: 1,
        enableDetailedLogging: true,
      },
      takserver: {
        hostname: 'tak',
        servicename: 'ops',
        branding: 'tak-nz',
        version: '5.4-RELEASE-19',
        useS3TAKServerConfigFile: false,
      },
      ecr: {
        imageRetentionCount: 5,
        scanOnPush: false,
      },
      general: {
        removalPolicy: 'DESTROY',
        enableDetailedLogging: true,
        enableContainerInsights: false,
      },
      webtak: {
        enableOidc: true,
        providerName: 'TAK-WebTAK',
        applicationName: 'WebTAK',
        applicationSlug: 'tak-webtak',
        openInNewTab: true,
        description: 'Web-based geospatial collaboration platform (Legacy system).',
      },
    };
  });

  test('creates WebTAK OIDC setup construct', () => {
    // Create a mock KMS key
    const kmsKey = new kms.Key(stack, 'TestKey');
    
    // Create a mock secret
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret', {
      encryptionKey: kmsKey,
    });

    // Create the WebTAK OIDC setup
    const webTakOidcSetup = new WebTakOidcSetup(stack, 'WebTakOidcSetup', {
      stackConfig: mockStackConfig,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
    });

    // Verify the construct was created
    expect(webTakOidcSetup).toBeDefined();
    expect(webTakOidcSetup.providerName).toBe('TAK-WebTAK');

    // Verify the template contains expected resources
    const template = Template.fromStack(stack);
    
    // Should have a Lambda function
    template.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'nodejs22.x',
      Handler: 'index.handler',
    });

    // Should have a custom resource
    template.hasResourceProperties('AWS::CloudFormation::CustomResource', {});

    // Should have IAM policies for the Lambda
    template.hasResourceProperties('AWS::IAM::Policy', {});
  });

  test('sets correct environment variables', () => {
    const kmsKey = new kms.Key(stack, 'TestKey');
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret', {
      encryptionKey: kmsKey,
    });

    new WebTakOidcSetup(stack, 'WebTakOidcSetup', {
      stackConfig: mockStackConfig,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
    });

    const template = Template.fromStack(stack);
    
    // Verify Lambda has correct environment variables
    template.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: {
          AUTHENTIK_URL: 'https://account.tak.nz',
          PROVIDER_NAME: 'TAK-WebTAK',
          APPLICATION_NAME: 'WebTAK',
          APPLICATION_SLUG: 'tak-webtak',
          LAUNCH_URL: 'https://ops.tak.nz',
          OPEN_IN_NEW_TAB: 'true',
          APPLICATION_DESCRIPTION: 'Web-based geospatial collaboration platform (Legacy system).',
        },
      },
    });
  });
});