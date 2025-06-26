/**
 * ELB Construct - Network load balancer and networking for TAK Server
 */
import { Construct } from 'constructs';
import {
  aws_ec2 as ec2,
  aws_elasticloadbalancingv2 as elbv2,
  aws_certificatemanager as acm,
  Duration,
  Fn
} from 'aws-cdk-lib';
import type { ContextEnvironmentConfig } from '../stack-config';
import type { InfrastructureConfig, NetworkConfig } from '../construct-configs';
import { TAK_SERVER_PORTS } from '../utils/constants';

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

    // Create network load balancer with dualstack IP addressing
    this.loadBalancer = new elbv2.NetworkLoadBalancer(this, 'NLB', {
      loadBalancerName: `${props.contextConfig.stackName.toLowerCase()}-tak`,
      vpc: props.infrastructure.vpc,
      internetFacing: true,
      ipAddressType: elbv2.IpAddressType.DUAL_STACK
    });

    // Create target groups for all TAK Server services
    this.targetGroups = {
      http: this.createTargetGroup('HttpTargetGroup', TAK_SERVER_PORTS.HTTP, props.infrastructure.vpc),
      cotTcp: this.createTargetGroup('CotTcpTargetGroup', TAK_SERVER_PORTS.COT_TCP, props.infrastructure.vpc),
      apiAdmin: this.createTargetGroup('ApiAdminTargetGroup', TAK_SERVER_PORTS.API_ADMIN, props.infrastructure.vpc),
      webtakAdmin: this.createTargetGroup('WebtakAdminTargetGroup', TAK_SERVER_PORTS.WEBTAK_ADMIN, props.infrastructure.vpc),
      federation: this.createTargetGroup('FederationTargetGroup', TAK_SERVER_PORTS.FEDERATION, props.infrastructure.vpc)
    };

    // Create listeners for all services
    this.loadBalancer.addListener('HttpListener', {
      port: TAK_SERVER_PORTS.HTTP,
      defaultTargetGroups: [this.targetGroups.http]
    });

    // Import SSL certificate for HTTPS listener
    const certificate = acm.Certificate.fromCertificateArn(this, 'ImportedCertificate', 
      Fn.importValue(props.network.sslCertificateArn)
    );

    // Port 443 maps to WebTAK Admin (8446) with SSL termination
    this.loadBalancer.addListener('HttpsListener', {
      port: TAK_SERVER_PORTS.HTTPS,
      protocol: elbv2.Protocol.TLS,
      certificates: [certificate],
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

    // Store the DNS name
    this.dnsName = this.loadBalancer.loadBalancerDnsName;
  }

  /**
   * Create a target group for TAK Server services
   */
  private createTargetGroup(id: string, port: number, vpc: ec2.IVpc): elbv2.NetworkTargetGroup {
    return new elbv2.NetworkTargetGroup(this, id, {
      vpc: vpc,
      targetType: elbv2.TargetType.IP,
      port: port,
      protocol: elbv2.Protocol.TCP,
      healthCheck: {
        protocol: elbv2.Protocol.TCP,
        port: port.toString(),
        interval: Duration.seconds(30),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 2
      }
    });
  }
}