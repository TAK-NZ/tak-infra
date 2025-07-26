import * as cdk from 'aws-cdk-lib';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import { Template } from 'aws-cdk-lib/assertions';
import { WebTakOidcSetup } from '../../../lib/constructs/webtak-oidc-setup';
import { ContextEnvironmentConfig } from '../../../lib/stack-config';

// Mock the NodejsFunction to avoid asset building
jest.mock('aws-cdk-lib/aws-lambda-nodejs', () => ({
  NodejsFunction: jest.fn().mockImplementation((scope, id, props) => {
    const { Function } = jest.requireActual('aws-cdk-lib/aws-lambda');
    return new Function(scope, id, {
      runtime: props.runtime,
      handler: props.handler,
      code: jest.requireActual('aws-cdk-lib/aws-lambda').Code.fromInline('exports.handler = async () => {};'),
      environment: props.environment,
      timeout: props.timeout,
      memorySize: props.memorySize,
      retryAttempts: props.retryAttempts
    });
  })
}));

describe('WebTakOidcSetup', () => {
  let app: cdk.App;
  let stack: cdk.Stack;
  let mockStackConfig: ContextEnvironmentConfig;

  beforeEach(() => {
    app = new cdk.App();
    stack = new cdk.Stack(app, 'TestStack');
    
    // Clear mocks
    jest.clearAllMocks();
    
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
      Handler: 'handler',
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

  test('handles secret without KMS key (fallback to wildcard)', () => {
    // Create secret without explicit KMS key to test line 91
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret');

    const webTakOidcSetup = new WebTakOidcSetup(stack, 'WebTakOidcSetup', {
      stackConfig: mockStackConfig,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
    });

    expect(webTakOidcSetup).toBeDefined();
    
    const template = Template.fromStack(stack);
    
    // Should have Lambda function and IAM policies (covers the KMS fallback logic)
    template.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'nodejs22.x'
    });
    
    template.resourceCountIs('AWS::IAM::Policy', 2);
  });

  test('includes optional configuration when provided', () => {
    const kmsKey = new kms.Key(stack, 'TestKey');
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret', {
      encryptionKey: kmsKey,
    });
    const webTakOidcClientSecret = new secretsmanager.Secret(stack, 'WebTakOidcClientSecret');

    // Enhanced config with optional fields (no iconPath to avoid file not found)
    const enhancedConfig: ContextEnvironmentConfig = {
      ...mockStackConfig,
      webtak: {
        ...mockStackConfig.webtak!,
        authenticationFlowName: 'custom-auth-flow',
        authorizationFlowName: 'custom-authz-flow',
        invalidationFlowName: 'custom-invalidation-flow',
        groupName: 'webtak-users',
        signingKeyName: 'custom-signing-key'
      },
      takserver: {
        ...mockStackConfig.takserver!,
        ldapGroupPrefix: 'tak_'
      }
    };

    new WebTakOidcSetup(stack, 'WebTakOidcSetup', {
      stackConfig: enhancedConfig,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
      webTakOidcClientSecret
    });

    const template = Template.fromStack(stack);
    
    // Verify optional environment variables are included
    template.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: {
          AUTHENTICATION_FLOW_NAME: 'custom-auth-flow',
          AUTHORIZATION_FLOW_NAME: 'custom-authz-flow',
          INVALIDATION_FLOW_NAME: 'custom-invalidation-flow',
          GROUP_NAME: 'webtak-users',
          LDAP_GROUP_PREFIX: 'tak_',
          SIGNING_KEY_NAME: 'custom-signing-key'
        }
      }
    });
  });

  test('handles missing webtak config gracefully', () => {
    const configWithoutWebtak: ContextEnvironmentConfig = {
      ...mockStackConfig,
      webtak: undefined
    };

    const kmsKey = new kms.Key(stack, 'TestKey');
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret', {
      encryptionKey: kmsKey,
    });

    const webTakOidcSetup = new WebTakOidcSetup(stack, 'WebTakOidcSetup', {
      stackConfig: configWithoutWebtak,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
    });

    // Should use default values
    expect(webTakOidcSetup.providerName).toBe('TAK-WebTAK');
    
    const template = Template.fromStack(stack);
    
    // Should have default environment variables
    template.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: {
          PROVIDER_NAME: 'TAK-WebTAK',
          APPLICATION_NAME: 'WebTAK',
          APPLICATION_SLUG: 'tak-webtak',
          OPEN_IN_NEW_TAB: 'true',
          APPLICATION_DESCRIPTION: 'Web-based geospatial collaboration platform (Legacy system).'
        }
      }
    });
  });

  test('sets openInNewTab to false when configured', () => {
    const configWithOpenInNewTabFalse: ContextEnvironmentConfig = {
      ...mockStackConfig,
      webtak: {
        ...mockStackConfig.webtak!,
        openInNewTab: false
      }
    };

    const kmsKey = new kms.Key(stack, 'TestKey');
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret', {
      encryptionKey: kmsKey,
    });

    new WebTakOidcSetup(stack, 'WebTakOidcSetup', {
      stackConfig: configWithOpenInNewTabFalse,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
    });

    const template = Template.fromStack(stack);
    
    template.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: {
          OPEN_IN_NEW_TAB: 'false'
        }
      }
    });
  });

  test('creates construct with fallback values', () => {
    const kmsKey = new kms.Key(stack, 'TestKey');
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret', {
      encryptionKey: kmsKey,
    });

    const webTakOidcSetup = new WebTakOidcSetup(stack, 'WebTakOidcSetup', {
      stackConfig: mockStackConfig,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
    });

    // Test that properties are defined (covers lines 151-167)
    expect(webTakOidcSetup.issuer).toBeDefined();
    expect(webTakOidcSetup.authorizeUrl).toBeDefined();
    expect(webTakOidcSetup.tokenUrl).toBeDefined();
    expect(webTakOidcSetup.userInfoUrl).toBeDefined();
    expect(webTakOidcSetup.jwksUri).toBeDefined();
    expect(webTakOidcSetup.providerName).toBe('TAK-WebTAK');

    const template = Template.fromStack(stack);
    
    // Should have custom resource and Lambda function
    template.hasResourceProperties('AWS::CloudFormation::CustomResource', {});
    template.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'nodejs22.x'
    });
  });

  test('handles custom resource attribute access errors', () => {
    const kmsKey = new kms.Key(stack, 'TestKey');
    const mockSecret = new secretsmanager.Secret(stack, 'TestSecret', {
      encryptionKey: kmsKey,
    });

    // Mock the CustomResource getAttString method to throw errors
    const originalGetAttString = cdk.CustomResource.prototype.getAttString;
    let callCount = 0;
    
    // Mock to simulate the error handling paths
    cdk.CustomResource.prototype.getAttString = jest.fn().mockImplementation((attributeName: string) => {
      callCount++;
      // First 7 calls (direct access) should fail
      if (callCount <= 7) {
        throw new Error('Direct access failed');
      }
      // Next 7 calls (Data prefix access) should also fail to trigger fallback
      if (callCount <= 14) {
        throw new Error('Data prefix access failed');
      }
      return 'mock-value';
    });

    const webTakOidcSetup = new WebTakOidcSetup(stack, 'WebTakOidcSetupError', {
      stackConfig: mockStackConfig,
      authentikAdminSecret: mockSecret,
      authentikUrl: 'https://account.tak.nz',
      webTakUrl: 'https://ops.tak.nz',
    });

    // Should fall back to error values and constructed URLs
    expect(webTakOidcSetup.clientId).toBe('error-retrieving-client-id');
    expect(webTakOidcSetup.clientSecret).toBe('error-retrieving-client-secret');
    expect(webTakOidcSetup.issuer).toBe('https://account.tak.nz/application/o/tak-webtak/');
    expect(webTakOidcSetup.authorizeUrl).toBe('https://account.tak.nz/application/o/authorize/');
    expect(webTakOidcSetup.tokenUrl).toBe('https://account.tak.nz/application/o/token/');
    expect(webTakOidcSetup.userInfoUrl).toBe('https://account.tak.nz/application/o/userinfo/');
    expect(webTakOidcSetup.jwksUri).toBe('https://account.tak.nz/application/o/jwks/');

    // Restore original method
    cdk.CustomResource.prototype.getAttString = originalGetAttString;
  });
});