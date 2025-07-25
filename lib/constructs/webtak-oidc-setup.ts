import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as cr from 'aws-cdk-lib/custom-resources';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as path from 'path';
import { Construct } from 'constructs';
import { ContextEnvironmentConfig } from '../stack-config';

export interface WebTakOidcSetupProps {
  readonly stackConfig: ContextEnvironmentConfig;
  readonly authentikAdminSecret: cdk.aws_secretsmanager.ISecret;
  readonly authentikUrl: string;
  readonly webTakUrl: string;
  readonly webTakOidcClientSecret?: cdk.aws_secretsmanager.ISecret;
}

export class WebTakOidcSetup extends Construct {
  public readonly clientId: string;
  public readonly clientSecret: string;
  public readonly providerName: string;
  public readonly issuer: string;
  public readonly authorizeUrl: string;
  public readonly tokenUrl: string;
  public readonly userInfoUrl: string;
  public readonly jwksUri: string;

  constructor(scope: Construct, id: string, props: WebTakOidcSetupProps) {
    super(scope, id);

    const { stackConfig, authentikAdminSecret, authentikUrl, webTakUrl } = props;
    
    // WebTAK OIDC configuration from stack config
    const webTakConfig = stackConfig.webtak;
    const providerName = webTakConfig?.providerName || 'TAK-WebTAK';
    const applicationName = webTakConfig?.applicationName || 'WebTAK';
    const applicationSlug = webTakConfig?.applicationSlug || 'tak-webtak';
    const openInNewTab = webTakConfig?.openInNewTab ?? true;
    const description = webTakConfig?.description || 'Web-based geospatial collaboration platform (Legacy system).';
    const redirectUri = `${webTakUrl}/login/redirect`;

    // Create Lambda function for Authentik OIDC setup
    const setupLambda = new nodejs.NodejsFunction(this, 'SetupLambda', {
      runtime: lambda.Runtime.NODEJS_22_X,
      entry: path.join(__dirname, '../../src/webtak-oidc-setup/index.js'),
      handler: 'handler',
      bundling: {
        minify: true,
        sourceMap: true,
        target: 'node22',
        externalModules: ['@aws-sdk/*'],
        nodeModules: ['axios', 'form-data'],
        forceDockerBundling: false,
        commandHooks: {
          beforeBundling: () => [],
          beforeInstall: () => [],
          afterBundling: (inputDir: string, outputDir: string) => [
            webTakConfig?.iconPath ? `cp ${inputDir}/${webTakConfig.iconPath} ${outputDir}/tak-logo.png` : 'echo "No icon specified"'
          ]
        }
      },
      timeout: cdk.Duration.minutes(10),
      memorySize: 512,
      retryAttempts: 2,
      environment: {
        AUTHENTIK_URL: authentikUrl,
        AUTHENTIK_ADMIN_SECRET_ARN: authentikAdminSecret.secretArn,
        PROVIDER_NAME: providerName,
        APPLICATION_NAME: applicationName,
        APPLICATION_SLUG: applicationSlug,
        REDIRECT_URIS: JSON.stringify([redirectUri]),
        LAUNCH_URL: webTakUrl,
        OPEN_IN_NEW_TAB: openInNewTab ? 'true' : 'false',
        APPLICATION_DESCRIPTION: description,
        ...(webTakConfig?.authenticationFlowName ? { AUTHENTICATION_FLOW_NAME: webTakConfig.authenticationFlowName } : {}),
        ...(webTakConfig?.authorizationFlowName ? { AUTHORIZATION_FLOW_NAME: webTakConfig.authorizationFlowName } : {}),
        ...(webTakConfig?.invalidationFlowName ? { INVALIDATION_FLOW_NAME: webTakConfig.invalidationFlowName } : {}),
        ...(webTakConfig?.groupName ? { GROUP_NAME: webTakConfig.groupName } : {}),
        ...(stackConfig.takserver?.ldapGroupPrefix ? { LDAP_GROUP_PREFIX: stackConfig.takserver.ldapGroupPrefix } : {}),
        ...(props.webTakOidcClientSecret ? { WEBTAK_OIDC_CLIENT_SECRET_ARN: props.webTakOidcClientSecret.secretArn } : {}),
        ...(webTakConfig?.signingKeyName ? { SIGNING_KEY_NAME: webTakConfig.signingKeyName } : {}),
      },
    });

    // Grant Lambda permission to read Authentik admin secret
    authentikAdminSecret.grantRead(setupLambda);
    
    // Grant Lambda permission to write WebTAK OIDC client secret
    if (props.webTakOidcClientSecret) {
      props.webTakOidcClientSecret.grantWrite(setupLambda);
    }
    
    // Grant Lambda permission to use KMS for decrypting secrets
    const kmsKeyId = authentikAdminSecret.encryptionKey?.keyArn || '*';
    
    setupLambda.addToRolePolicy(new iam.PolicyStatement({
      actions: [
        'kms:Decrypt',
        'kms:DescribeKey',
        'kms:GenerateDataKey',
        'kms:Encrypt'
      ],
      resources: [kmsKeyId]
    }));
    
    setupLambda.addToRolePolicy(new iam.PolicyStatement({
      actions: ['secretsmanager:ListSecrets'],
      resources: ['*']
    }));

    // Create custom resource to invoke Lambda during deployment
    const provider = new cr.Provider(this, 'Provider', {
      onEventHandler: setupLambda,
      logGroup: new logs.LogGroup(this, 'ProviderLogGroup', {
        retention: logs.RetentionDays.ONE_WEEK,
        removalPolicy: cdk.RemovalPolicy.DESTROY
      })
    });

    // Create custom resource that will invoke the Lambda
    const customResource = new cdk.CustomResource(this, 'OidcSetupResource', {
      serviceToken: provider.serviceToken,
      properties: {
        providerName: providerName,
        applicationName: applicationName,
        applicationSlug: applicationSlug,
        redirectUris: JSON.stringify([redirectUri]),
        launchUrl: webTakUrl,
        groupName: webTakConfig?.groupName || '',
        UpdateTimestamp: Date.now().toString()
      },
    });

    // Set provider name from config
    this.providerName = providerName;
    
    // Get the attributes from custom resource with dual-access pattern
    let directAccess = false;
    try {
      this.clientId = customResource.getAttString('clientId');
      this.clientSecret = customResource.getAttString('clientSecret');
      this.issuer = customResource.getAttString('issuer');
      this.authorizeUrl = customResource.getAttString('authorizeUrl');
      this.tokenUrl = customResource.getAttString('tokenUrl');
      this.userInfoUrl = customResource.getAttString('userInfoUrl');
      this.jwksUri = customResource.getAttString('jwksUri');
      directAccess = true;
    } catch (error) {
      // Try with Data prefix if direct access failed
      try {
        this.clientId = customResource.getAttString('Data.clientId');
        this.clientSecret = customResource.getAttString('Data.clientSecret');
        this.issuer = customResource.getAttString('Data.issuer');
        this.authorizeUrl = customResource.getAttString('Data.authorizeUrl');
        this.tokenUrl = customResource.getAttString('Data.tokenUrl') || customResource.getAttString('Data.token_endpoint');
        this.userInfoUrl = customResource.getAttString('Data.userInfoUrl') || customResource.getAttString('Data.userinfo_endpoint');
        this.jwksUri = customResource.getAttString('Data.jwksUri') || customResource.getAttString('Data.jwks_uri');
      } catch (nestedError) {
        // Fallback values if both access methods fail
        this.clientId = 'error-retrieving-client-id';
        this.clientSecret = 'error-retrieving-client-secret';
        this.issuer = `${authentikUrl}/application/o/${applicationSlug}/`;
        this.authorizeUrl = `${authentikUrl}/application/o/authorize/`;
        this.tokenUrl = `${authentikUrl}/application/o/token/`;
        this.userInfoUrl = `${authentikUrl}/application/o/userinfo/`;
        this.jwksUri = `${authentikUrl}/application/o/jwks/`;
      }
    }
    
    // Add debug output
    new cdk.CfnOutput(this, 'WebTakOidcSetupDebug', {
      value: JSON.stringify({
        clientIdAvailable: this.clientId !== 'error-retrieving-client-id',
        issuerAvailable: this.issuer.startsWith('http'),
        accessMethod: directAccess ? 'direct' : 'nested',
        clientId: this.clientId,
        issuer: this.issuer
      }),
      description: 'WebTAK OIDC setup debug information',
    });
  }
}