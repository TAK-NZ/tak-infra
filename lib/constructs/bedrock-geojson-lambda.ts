import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as path from 'path';
import { Construct } from 'constructs';

export class BedrockGeoJsonLambda extends Construct {
  public readonly fn: lambda.Function;

  constructor(scope: Construct, id: string) {
    super(scope, id);

    this.fn = new lambda.Function(this, 'Fn', {
      runtime: lambda.Runtime.PYTHON_3_12,
      code: lambda.Code.fromAsset(path.join(__dirname, '../../lambda/geojson-query')),
      handler: 'index.handler',
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      description: 'Bedrock Agent action group: fetch and spatially filter GeoJSON from a URL',
    });

    // Allow Bedrock to invoke this Lambda
    this.fn.addPermission('BedrockInvoke', {
      principal: new iam.ServicePrincipal('bedrock.amazonaws.com'),
      action: 'lambda:InvokeFunction',
    });
  }
}
