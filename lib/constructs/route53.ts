/**
 * Route53 Construct - DNS record management for TAK Server
 * 
 * This construct creates DNS records for TAK Server, allowing the FQDN to be
 * available for use by other constructs before the ECS service is created.
 */
import { Construct } from 'constructs';
import {
  aws_route53 as route53,
  aws_route53_targets as targets,
  aws_elasticloadbalancingv2 as elbv2
} from 'aws-cdk-lib';
import type { ContextEnvironmentConfig } from '../stack-config';
import type { NetworkConfig } from '../construct-configs';

/**
 * Properties for the Route53 construct
 */
export interface Route53Props {
  /**
   * Environment name (e.g. 'prod', 'dev-test')
   */
  environment: 'prod' | 'dev-test';

  /**
   * Environment configuration
   */
  contextConfig: ContextEnvironmentConfig;

  /**
   * Network configuration (DNS zones, hostname, load balancer)
   */
  network: NetworkConfig;

  /**
   * TAK Server Network Load Balancer for A/AAAA alias records
   */
  takLoadBalancer: elbv2.NetworkLoadBalancer;
}

/**
 * CDK construct for Route53 DNS record management - TAK Server
 */
export class Route53 extends Construct {
  /**
   * The hosted zone reference
   */
  public readonly hostedZone: route53.IHostedZone;

  /**
   * TAK Server A record
   */
  public readonly takARecord: route53.ARecord;

  /**
   * TAK Server AAAA record
   */
  public readonly takAAAARecord: route53.AaaaRecord;

  /**
   * Service A record
   */
  public readonly serviceARecord: route53.ARecord;

  /**
   * Service AAAA record
   */
  public readonly serviceAAAARecord: route53.AaaaRecord;

  /**
   * Full DNS name for TAK Server
   */
  public readonly takFqdn: string;

  /**
   * Full DNS name for Service
   */
  public readonly serviceFqdn: string;

  constructor(scope: Construct, id: string, props: Route53Props) {
    super(scope, id);

    // Import the hosted zone from base infrastructure
    this.hostedZone = route53.HostedZone.fromHostedZoneAttributes(this, 'HostedZone', {
      hostedZoneId: props.network.hostedZoneId,
      zoneName: props.network.hostedZoneName
    });

    // Calculate full domain names
    this.takFqdn = `${props.network.hostname}.${props.network.hostedZoneName}`;
    this.serviceFqdn = `${props.contextConfig.takserver.servicename}.${props.network.hostedZoneName}`;

    // Create A record alias for TAK Server (IPv4)
    this.takARecord = new route53.ARecord(this, 'TakARecord', {
      zone: this.hostedZone,
      recordName: props.network.hostname,
      target: route53.RecordTarget.fromAlias(
        new targets.LoadBalancerTarget(props.takLoadBalancer)
      ),
      comment: `TAK Server IPv4 alias record for ${props.environment} environment`
    });

    // Create AAAA record alias for TAK Server (IPv6)
    this.takAAAARecord = new route53.AaaaRecord(this, 'TakAAAARecord', {
      zone: this.hostedZone,
      recordName: props.network.hostname,
      target: route53.RecordTarget.fromAlias(
        new targets.LoadBalancerTarget(props.takLoadBalancer)
      ),
      comment: `TAK Server IPv6 alias record for ${props.environment} environment`
    });

    // Create A record alias for Service (IPv4)
    this.serviceARecord = new route53.ARecord(this, 'ServiceARecord', {
      zone: this.hostedZone,
      recordName: props.contextConfig.takserver.servicename,
      target: route53.RecordTarget.fromAlias(
        new targets.LoadBalancerTarget(props.takLoadBalancer)
      ),
      comment: `TAK Service IPv4 alias record for ${props.environment} environment`
    });

    // Create AAAA record alias for Service (IPv6)
    this.serviceAAAARecord = new route53.AaaaRecord(this, 'ServiceAAAARecord', {
      zone: this.hostedZone,
      recordName: props.contextConfig.takserver.servicename,
      target: route53.RecordTarget.fromAlias(
        new targets.LoadBalancerTarget(props.takLoadBalancer)
      ),
      comment: `TAK Service IPv6 alias record for ${props.environment} environment`
    });
  }

  /**
   * Get the TAK Server service URL
   */
  public getTakUrl(): string {
    return `https://${this.takFqdn}:8443`;
  }

  /**
   * Get the TAK Service URL
   */
  public getServiceUrl(): string {
    return `https://${this.serviceFqdn}`;
  }

  /**
   * Get the TAK Server certificate enrollment URL
   */
  public getCertEnrollmentUrl(): string {
    return `https://${this.serviceFqdn}:8446`;
  }
}