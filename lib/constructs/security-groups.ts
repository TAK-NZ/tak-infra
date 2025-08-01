/**
 * Security Groups Construct - Centralized security group management for TAK Server
 */
import { Construct } from 'constructs';
import {
  aws_ec2 as ec2,
  Fn
} from 'aws-cdk-lib';
import { createBaseImportValue, BASE_EXPORT_NAMES } from '../cloudformation-imports';
import { DATABASE_CONSTANTS, TAK_SERVER_PORTS, EFS_CONSTANTS } from '../utils/constants';

/**
 * Properties for the SecurityGroups construct
 */
export interface SecurityGroupsProps {
  /**
   * VPC to create security groups in
   */
  vpc: ec2.IVpc;

  /**
   * Stack name component for imports
   */
  stackNameComponent: string;
}

/**
 * CDK construct for all security groups
 */
export class SecurityGroups extends Construct {
  /**
   * Security group for NLB
   */
  public readonly nlb: ec2.SecurityGroup;

  /**
   * Security group for TAK Server ECS tasks
   */
  public readonly takServer: ec2.SecurityGroup;

  /**
   * Security group for database access
   */
  public readonly database: ec2.SecurityGroup;

  /**
   * Security group for EFS access
   */
  public readonly efs: ec2.SecurityGroup;

  constructor(scope: Construct, id: string, props: SecurityGroupsProps) {
    super(scope, id);

    // Create all security groups first
    this.nlb = new ec2.SecurityGroup(this, 'NLB', {
      vpc: props.vpc,
      description: 'Allow TAK Traffic into NLB',
      allowAllOutbound: false
    });

    this.takServer = new ec2.SecurityGroup(this, 'TakServer', {
      vpc: props.vpc,
      description: 'Security group for TAK Server ECS tasks',
      allowAllOutbound: false
    });

    this.database = new ec2.SecurityGroup(this, 'AuroraDB', {
      vpc: props.vpc,
      description: 'Security group for database',
      allowAllOutbound: false
    });

    this.efs = new ec2.SecurityGroup(this, 'EFS', {
      vpc: props.vpc,
      description: 'Security group for EFS access',
      allowAllOutbound: false
    });

    // Now add all the rules with cross-references
    this.addNlbRules(props);
    this.addTakServerRules();
    this.addDatabaseRules();
    this.addEfsRules();
  }

  /**
   * Add NLB security group rules
   */
  private addNlbRules(props: SecurityGroupsProps): void {
    // Add inbound rules for all TAK Server ports
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTP),
      'Allow HTTP traffic from internet'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTPS),
      'Allow HTTPS traffic from internet'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(TAK_SERVER_PORTS.COT_TCP),
      'Allow CoT TCP traffic from internet'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(TAK_SERVER_PORTS.API_ADMIN),
      'Allow API Admin traffic from internet'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(TAK_SERVER_PORTS.WEBTAK_ADMIN),
      'Allow WebTAK Admin traffic from internet'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(TAK_SERVER_PORTS.FEDERATION),
      'Allow Federation traffic from internet'
    );

    // IPv6 rules for NLB
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTP),
      'Allow HTTP traffic from internet IPv6'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTPS),
      'Allow HTTPS traffic from internet IPv6'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(TAK_SERVER_PORTS.COT_TCP),
      'Allow CoT TCP traffic from internet IPv6'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(TAK_SERVER_PORTS.API_ADMIN),
      'Allow API Admin traffic from internet IPv6'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(TAK_SERVER_PORTS.WEBTAK_ADMIN),
      'Allow WebTAK Admin traffic from internet IPv6'
    );
    this.nlb.addIngressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(TAK_SERVER_PORTS.FEDERATION),
      'Allow Federation traffic from internet IPv6'
    );

    // NLB outbound rules for health checks to VPC (IPv4 and IPv6)
    const vpcCidrIpv4 = Fn.importValue(createBaseImportValue(props.stackNameComponent, BASE_EXPORT_NAMES.VPC_CIDR_IPV4));
    const vpcCidrIpv6 = Fn.importValue(createBaseImportValue(props.stackNameComponent, BASE_EXPORT_NAMES.VPC_CIDR_IPV6));
    
    this.nlb.addEgressRule(
      ec2.Peer.ipv4(vpcCidrIpv4),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTP),
      'Health check to VPC HTTP'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv4(vpcCidrIpv4),
      ec2.Port.tcp(TAK_SERVER_PORTS.COT_TCP),
      'Health check to VPC CoT TCP'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv4(vpcCidrIpv4),
      ec2.Port.tcp(TAK_SERVER_PORTS.API_ADMIN),
      'Health check to VPC API Admin'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv4(vpcCidrIpv4),
      ec2.Port.tcp(TAK_SERVER_PORTS.WEBTAK_ADMIN),
      'Health check to VPC WebTAK Admin'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv4(vpcCidrIpv4),
      ec2.Port.tcp(TAK_SERVER_PORTS.FEDERATION),
      'Health check to VPC Federation'
    );
    
    // IPv6 egress rules
    this.nlb.addEgressRule(
      ec2.Peer.ipv6(vpcCidrIpv6),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTP),
      'Health check to VPC HTTP IPv6'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv6(vpcCidrIpv6),
      ec2.Port.tcp(TAK_SERVER_PORTS.COT_TCP),
      'Health check to VPC CoT TCP IPv6'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv6(vpcCidrIpv6),
      ec2.Port.tcp(TAK_SERVER_PORTS.API_ADMIN),
      'Health check to VPC API Admin IPv6'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv6(vpcCidrIpv6),
      ec2.Port.tcp(TAK_SERVER_PORTS.WEBTAK_ADMIN),
      'Health check to VPC WebTAK Admin IPv6'
    );
    this.nlb.addEgressRule(
      ec2.Peer.ipv6(vpcCidrIpv6),
      ec2.Port.tcp(TAK_SERVER_PORTS.FEDERATION),
      'Health check to VPC Federation IPv6'
    );
  }

  /**
   * Add TAK Server security group rules
   */
  private addTakServerRules(): void {
    // Allow TAK Server traffic from NLB
    this.takServer.addIngressRule(
      ec2.Peer.securityGroupId(this.nlb.securityGroupId),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTP),
      'Allow HTTP traffic from NLB'
    );
    this.takServer.addIngressRule(
      ec2.Peer.securityGroupId(this.nlb.securityGroupId),
      ec2.Port.tcp(TAK_SERVER_PORTS.HTTPS),
      'Allow HTTPS traffic from NLB'
    );
    this.takServer.addIngressRule(
      ec2.Peer.securityGroupId(this.nlb.securityGroupId),
      ec2.Port.tcp(TAK_SERVER_PORTS.COT_TCP),
      'Allow CoT TCP traffic from NLB'
    );
    this.takServer.addIngressRule(
      ec2.Peer.securityGroupId(this.nlb.securityGroupId),
      ec2.Port.tcp(TAK_SERVER_PORTS.API_ADMIN),
      'Allow API Admin traffic from NLB'
    );
    this.takServer.addIngressRule(
      ec2.Peer.securityGroupId(this.nlb.securityGroupId),
      ec2.Port.tcp(TAK_SERVER_PORTS.WEBTAK_ADMIN),
      'Allow WebTAK Admin traffic from NLB'
    );
    this.takServer.addIngressRule(
      ec2.Peer.securityGroupId(this.nlb.securityGroupId),
      ec2.Port.tcp(TAK_SERVER_PORTS.FEDERATION),
      'Allow Federation traffic from NLB'
    );

    // TAK Server outbound rules
    this.addTakServerOutboundRules(this.takServer);
  }

  /**
   * Add database security group rules
   */
  private addDatabaseRules(): void {
    this.database.addIngressRule(
      ec2.Peer.securityGroupId(this.takServer.securityGroupId),
      ec2.Port.tcp(DATABASE_CONSTANTS.PORT),
      'Allow PostgreSQL access from TAK Server'
    );
  }

  /**
   * Add EFS security group rules
   */
  private addEfsRules(): void {
    this.efs.addIngressRule(
      ec2.Peer.securityGroupId(this.takServer.securityGroupId),
      ec2.Port.tcp(EFS_CONSTANTS.PORT),
      'Allow NFS access from TAK Server'
    );
  }

  /**
   * Add standard TAK Server outbound rules
   */
  private addTakServerOutboundRules(securityGroup: ec2.SecurityGroup): void {
    // Database access
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(DATABASE_CONSTANTS.PORT),
      'Allow PostgreSQL access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(DATABASE_CONSTANTS.PORT),
      'Allow PostgreSQL access IPv6'
    );

    // EFS access
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(EFS_CONSTANTS.PORT),
      'Allow EFS access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(EFS_CONSTANTS.PORT),
      'Allow EFS access IPv6'
    );

    // HTTPS access for external services (LDAP, OAuth, etc.)
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(443),
      'Allow HTTPS access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(443),
      'Allow HTTPS access IPv6'
    );

    // LDAP/LDAPS access for authentication
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(389),
      'Allow LDAP access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(389),
      'Allow LDAP access IPv6'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(636),
      'Allow LDAPS access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(636),
      'Allow LDAPS access IPv6'
    );

    // TAK-specific outbound rules for federation and signaling
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(8089),
      'Allow TAK Signaling access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(8089),
      'Allow TAK Signaling access IPv6'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(9000),
      'Allow Federation access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(9000),
      'Allow Federation access IPv6'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(9001),
      'Allow Federation access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(9001),
      'Allow Federation access IPv6'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(9102),
      'Allow FederationHUB access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(9102),
      'Allow FederationHUB access IPv6'
    );

    // DNS rules
    this.addDnsRules(securityGroup);
  }

  /**
   * Add DNS rules (TCP and UDP port 53)
   */
  private addDnsRules(securityGroup: ec2.SecurityGroup): void {
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(53),
      'Allow DNS access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.tcp(53),
      'Allow DNS access IPv6'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.udp(53),
      'Allow DNS access'
    );
    securityGroup.addEgressRule(
      ec2.Peer.anyIpv6(),
      ec2.Port.udp(53),
      'Allow DNS access IPv6'
    );
  }
}