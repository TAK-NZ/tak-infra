import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as path from 'path';
import { Construct } from 'constructs';

interface BedrockArcGisLambdaProps {
  kmsKey: kms.IKey;
}

export class BedrockArcGisLambda extends Construct {
  public readonly fn: lambda.Function;
  public readonly secret: secretsmanager.Secret;

  constructor(scope: Construct, id: string, props: BedrockArcGisLambdaProps) {
    super(scope, id);

    this.secret = new secretsmanager.Secret(this, 'ArcGisCredentials', {
      secretName: `tak-arcgis-credentials`,
      description: 'ArcGIS OAuth2 client credentials for Bedrock geocode Lambda',
      encryptionKey: props.kmsKey,
      secretObjectValue: {
        clientId: cdk.SecretValue.unsafePlainText('REPLACE_ME'),
        clientSecret: cdk.SecretValue.unsafePlainText('REPLACE_ME'),
      },
    });

    this.fn = new lambda.Function(this, 'Fn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      code: lambda.Code.fromAsset(path.join(__dirname, '../../lambda/arcgis-geocode')),
      handler: 'index.handler',
      timeout: cdk.Duration.seconds(15),
      memorySize: 256,
      description: 'Bedrock Agent action group: ArcGIS forward and reverse geocoding',
      environment: {
        ARCGIS_SECRET_ARN: this.secret.secretArn,
      },
    });

    this.secret.grantRead(this.fn);
    props.kmsKey.grantDecrypt(this.fn);

    this.fn.addPermission('BedrockInvoke', {
      principal: new iam.ServicePrincipal('bedrock.amazonaws.com'),
      action: 'lambda:InvokeFunction',
    });
  }
}
