/**
 * Constants for TAK infrastructure
 */

export const DEFAULT_AWS_REGION = 'ap-southeast-2';

export const TAK_SERVER_PORTS = {
  HTTP: 80,
  HTTPS: 443,
  COT_TCP: 8089,
  API_ADMIN: 8443,
  WEBTAK_ADMIN: 8446,
  FEDERATION: 9001,
} as const;