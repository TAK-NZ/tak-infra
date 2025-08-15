/**
 * ELB Construct - Network load balancer and networking for TAK Server
 */
import { Construct } from 'constructs';
import {
  aws_ec2 as ec2,
  aws_elasticloadbalancingv2 as elbv2,
  aws_certificatemanager as acm,
  aws_s3 as s3,
  Duration,
  Fn
} from 'aws-cdk-lib';
import type { ContextEnvironmentConfig } from '../stack-config';
import type { InfrastructureConfig, NetworkConfig } from '../construct-configs';
import { TAK_SERVER_PORTS } from '../utils/constants';
import { createBaseImportValue, BASE_EXPORT_NAMES } from '../cloudformation-imports';

/**
 * Properties for the ELB construct
 */
export interface ELBProps {
  /**
   * Environment type ('prod' | 'dev-test')
   */
  environment: 'prod' | 'dev-test';

  /**
   * Context-based environment configuration (direct from cdk.json)
   */
  contextConfig: ContextEnvironmentConfig;

  /**
   * Infrastructure configuration (VPC, security groups, etc.)
   */
  infrastructure: InfrastructureConfig;

  /**
   * Network configuration (SSL certs, hostnames, etc.)
   */
  network: NetworkConfig;

  /**
   * NLB security group
   */
  nlbSecurityGroup: ec2.ISecurityGroup;
}

/**
 * CDK construct for the Network Load Balancer for TAK Server
 */
export class Elb extends Construct {
  /**
   * The network load balancer
   */
  public readonly loadBalancer: elbv2.NetworkLoadBalancer;

  /**
   * Target groups for different TAK Server services
   */
  public readonly targetGroups: {
    http: elbv2.NetworkTargetGroup;
    cotTcp: elbv2.NetworkTargetGroup;
    apiAdmin: elbv2.NetworkTargetGroup;
    webtakAdmin: elbv2.NetworkTargetGroup;
    federation: elbv2.NetworkTargetGroup;
  };

  /**
   * DNS name of the load balancer
   */
  public readonly dnsName: string;

  constructor(scope: Construct, id: string, props: ELBProps) {
    super(scope, id);

    // Create network load balancer with dualstack IP addressing and security group
    this.loadBalancer = new elbv2.NetworkLoadBalancer(this, 'NLB', {
      loadBalancerName: `tak-${props.contextConfig.stackName.toLowerCase()}-tak`,
      vpc: props.infrastructure.vpc,
      internetFacing: true,
      ipAddressType: elbv2.IpAddressType.DUAL_STACK,
      securityGroups: [props.nlbSecurityGroup]
    });

    // Create target groups for all TAK Server services
    this.targetGroups = {
      http: this.createTargetGroup('HttpTargetGroup', TAK_SERVER_PORTS.HTTP, props.infrastructure.vpc, props),
      cotTcp: this.createTargetGroup('CotTcpTargetGroup', TAK_SERVER_PORTS.COT_TCP, props.infrastructure.vpc, props),
      apiAdmin: this.createTargetGroup('ApiAdminTargetGroup', TAK_SERVER_PORTS.API_ADMIN, props.infrastructure.vpc, props),
      webtakAdmin: this.createTargetGroup('WebtakAdminTargetGroup', TAK_SERVER_PORTS.WEBTAK_ADMIN, props.infrastructure.vpc, props),
      federation: this.createTargetGroup('FederationTargetGroup', TAK_SERVER_PORTS.FEDERATION, props.infrastructure.vpc, props)
    };

    // Create listeners for all services
    this.loadBalancer.addListener('HttpListener', {
      port: TAK_SERVER_PORTS.HTTP,
      defaultTargetGroups: [this.targetGroups.http]
    });

    // Port 443 maps to WebTAK Admin (8446) without TLS termination
    this.loadBalancer.addListener('HttpsListener', {
      port: TAK_SERVER_PORTS.HTTPS,
      protocol: elbv2.Protocol.TCP,
      defaultTargetGroups: [this.targetGroups.webtakAdmin]
    });

    this.loadBalancer.addListener('CotTcpListener', {
      port: TAK_SERVER_PORTS.COT_TCP,
      defaultTargetGroups: [this.targetGroups.cotTcp]
    });

    this.loadBalancer.addListener('ApiAdminListener', {
      port: TAK_SERVER_PORTS.API_ADMIN,
      defaultTargetGroups: [this.targetGroups.apiAdmin]
    });

    this.loadBalancer.addListener('WebtakAdminListener', {
      port: TAK_SERVER_PORTS.WEBTAK_ADMIN,
      defaultTargetGroups: [this.targetGroups.webtakAdmin]
    });

    this.loadBalancer.addListener('FederationListener', {
      port: TAK_SERVER_PORTS.FEDERATION,
      defaultTargetGroups: [this.targetGroups.federation]
    });

    // Import S3 logs bucket from BaseInfra
    const logsBucket = s3.Bucket.fromBucketArn(this, 'ImportedLogsBucket',
      Fn.importValue(createBaseImportValue(props.contextConfig.stackName, BASE_EXPORT_NAMES.S3_ELB_LOGS))
    );

    // Enable NLB access logging
    this.loadBalancer.setAttribute('access_logs.s3.enabled', 'true');
    this.loadBalancer.setAttribute('access_logs.s3.bucket', logsBucket.bucketName);
    this.loadBalancer.setAttribute('access_logs.s3.prefix', `TAK-${props.contextConfig.stackName}-TakInfra`);

    // Store the DNS name
    this.dnsName = this.loadBalancer.loadBalancerDnsName;
  }

  /**
   * Create a target group for TAK Server services
   */
  private createTargetGroup(id: string, port: number, vpc: ec2.IVpc, props: ELBProps): elbv2.NetworkTargetGroup {
    const healthCheckPort = port === TAK_SERVER_PORTS.HTTP ? TAK_SERVER_PORTS.WEBTAK_ADMIN : port;
    
    // Create readable target group names
    const nameMap: { [key: string]: string } = {
      'HttpTargetGroup': 'certbot',
      'CotTcpTargetGroup': 'cot-tcp',
      'ApiAdminTargetGroup': 'api-admin',
      'WebtakAdminTargetGroup': 'webtak-admin',
      'FederationTargetGroup': 'federation'
    };
    
    return new elbv2.NetworkTargetGroup(this, id, {
      targetGroupName: `tak-${props.contextConfig.stackName.toLowerCase()}-${nameMap[id]}`,
      vpc: vpc,
      targetType: elbv2.TargetType.IP,
      port: port,
      protocol: elbv2.Protocol.TCP,
      deregistrationDelay: Duration.seconds(0),
      preserveClientIp: true,
      healthCheck: {
        protocol: elbv2.Protocol.TCP,
        port: healthCheckPort.toString(),
        interval: Duration.seconds(5),
        timeout: Duration.seconds(2),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 2
      }
    });
  }
}