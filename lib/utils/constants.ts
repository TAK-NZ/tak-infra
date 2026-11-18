/**
 * Constants for TAK infrastructure
 */

export const DEFAULT_AWS_REGION = 'ap-southeast-2';
/**
 * Regions where Amazon Bedrock Knowledge Bases (AWS::Bedrock::KnowledgeBase, AWS::Bedrock::DataSource) are not
 * available, so the stack creates no knowledge bases there. Bedrock model inference may still work in them
 * (ap-southeast-6, Auckland, has it through cross-Region inference profiles). Remove a region from this list once
 * AWS adds the service there. Checked 2026-11-18: the Bedrock Agents and Knowledge Bases region tables do not
 * list ap-southeast-6, and its Knowledge Bases API returns an internal server error.
 */
export const BEDROCK_KB_UNSUPPORTED_REGIONS: readonly string[] = ['ap-southeast-6'];

export const DATABASE_CONSTANTS = {
  PORT: 5432,
  PASSWORD_LENGTH: 64,
  DEFAULT_DATABASE_NAME: 'takserver',
  USERNAME: 'tak'
} as const;

export const TAK_SERVER_PORTS = {
  HTTP: 80,
  HTTPS: 443,
  COT_TCP: 8089,
  API_ADMIN: 8443,
  WEBTAK_ADMIN: 8446,
  FEDERATION: 9001,
} as const;

export const EFS_CONSTANTS = {
  PORT: 2049
} as const;