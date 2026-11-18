import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3vectors from 'aws-cdk-lib/aws-s3vectors';
import * as bedrock from 'aws-cdk-lib/aws-bedrock';
import { Aws, RemovalPolicy } from 'aws-cdk-lib';
import { Construct } from 'constructs';

/** Titan Text Embeddings V2 produces 1024-dimension vectors at the default setting. */
const EMBEDDING_MODEL_ID = 'amazon.titan-embed-text-v2:0';
const EMBEDDING_DIMENSIONS = 1024;

/**
 * Lower-case letters, digits, hyphens and dots, 3 to 63 characters, no leading or trailing
 * separator. This is the S3 Vectors index-name rule, which is the strictest of the names derived
 * from the knowledge base name.
 */
const KB_NAME_PATTERN = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/;

export interface BedrockKnowledgeBaseProps {
  /**
   * Knowledge base name. It is also the S3 prefix of the source documents
   * (`bedrock-kb/<name>/`) and the vector index name, so it must match the folder the
   * documents are uploaded to (for example `nema-cdem`).
   */
  readonly name: string;
  /** Bucket holding the source documents (the base-infra TAK Images bucket). */
  readonly sourceBucket: s3.IBucket;
  /** KMS key that encrypts the source bucket. The knowledge base role needs `kms:Decrypt` on it. */
  readonly sourceBucketKey: kms.IKey;
  readonly removalPolicy: RemovalPolicy;
}

/**
 * Bedrock Knowledge Base backed by Amazon S3 Vectors, fed from `bedrock-kb/<name>/` in the
 * TAK Images bucket.
 *
 * S3 Vectors replaces the OpenSearch Serverless collection that `scripts/bedrock/setup-bedrock-agent.py`
 * used to create: no always-on OCUs, no cold start, and no collection, security policies or index
 * mapping to manage. Ingestion is not stack state. After the documents change, run an ingestion job
 * (`aws bedrock-agent start-ingestion-job`, or `setup-bedrock-agent.py`, which does so when the
 * knowledge base has never been synced).
 */
export class BedrockKnowledgeBase extends Construct {
  public readonly knowledgeBase: bedrock.CfnKnowledgeBase;
  public readonly dataSource: bedrock.CfnDataSource;
  public readonly vectorBucket: s3vectors.CfnVectorBucket;
  public readonly vectorIndex: s3vectors.CfnIndex;
  public readonly role: iam.Role;

  constructor(scope: Construct, id: string, props: BedrockKnowledgeBaseProps) {
    super(scope, id);

    const { name } = props;
    if (!KB_NAME_PATTERN.test(name)) {
      throw new Error(
        `Invalid Bedrock knowledge base name '${name}': use 3 to 63 lower-case letters, digits and hyphens, ` +
        'starting and ending with a letter or digit (it is also the S3 folder name under bedrock-kb/)'
      );
    }

    const prefix = `bedrock-kb/${name}/`;
    const embeddingModelArn = `arn:${Aws.PARTITION}:bedrock:${Aws.REGION}::foundation-model/${EMBEDDING_MODEL_ID}`;

    // Vector storage. The bucket name is generated so the resource can be replaced without a clash.
    this.vectorBucket = new s3vectors.CfnVectorBucket(this, 'VectorBucket');
    this.vectorIndex = new s3vectors.CfnIndex(this, 'VectorIndex', {
      vectorBucketArn: this.vectorBucket.attrVectorBucketArn,
      indexName: name,
      dataType: 'float32',
      dimension: EMBEDDING_DIMENSIONS,
      distanceMetric: 'cosine',
      // Bedrock stores each chunk's text and metadata as vector metadata. Filterable metadata is
      // limited to 2 KB per vector, so the chunk text must be marked non-filterable.
      metadataConfiguration: {
        nonFilterableMetadataKeys: ['AMAZON_BEDROCK_TEXT', 'AMAZON_BEDROCK_METADATA'],
      },
    });
    this.vectorIndex.addDependency(this.vectorBucket);

    // Service role assumed by Bedrock to read the documents, embed them and write the vectors.
    this.role = new iam.Role(this, 'Role', {
      description: `Bedrock knowledge base ${name}: read bedrock-kb/${name}/, embed, write S3 Vectors index`,
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com', {
        conditions: {
          StringEquals: { 'aws:SourceAccount': Aws.ACCOUNT_ID },
          ArnLike: { 'aws:SourceArn': `arn:${Aws.PARTITION}:bedrock:${Aws.REGION}:${Aws.ACCOUNT_ID}:knowledge-base/*` },
        },
      }),
    });
    this.role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:ListBucket'],
      resources: [props.sourceBucket.bucketArn],
      conditions: { StringLike: { 's3:prefix': [`${prefix}*`] } },
    }));
    this.role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject'],
      resources: [props.sourceBucket.arnForObjects(`${prefix}*`)],
    }));
    this.role.addToPolicy(new iam.PolicyStatement({
      actions: ['kms:Decrypt'],
      resources: [props.sourceBucketKey.keyArn],
    }));
    this.role.addToPolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: [embeddingModelArn],
    }));
    this.role.addToPolicy(new iam.PolicyStatement({
      actions: [
        's3vectors:GetIndex',
        's3vectors:QueryVectors',
        's3vectors:PutVectors',
        's3vectors:GetVectors',
        's3vectors:DeleteVectors',
      ],
      resources: [this.vectorIndex.attrIndexArn],
    }));

    // Named `<name>-s3v` so it never collides with a knowledge base of the same name created by
    // the old script, which looks knowledge bases up by name.
    this.knowledgeBase = new bedrock.CfnKnowledgeBase(this, 'KnowledgeBase', {
      name: `${name}-s3v`,
      description: `TAK-GPT knowledge base for bedrock-kb/${name}/ (S3 Vectors)`,
      roleArn: this.role.roleArn,
      knowledgeBaseConfiguration: {
        type: 'VECTOR',
        vectorKnowledgeBaseConfiguration: {
          embeddingModelArn,
          embeddingModelConfiguration: {
            bedrockEmbeddingModelConfiguration: {
              dimensions: EMBEDDING_DIMENSIONS,
              embeddingDataType: 'FLOAT32',
            },
          },
        },
      },
      storageConfiguration: {
        type: 'S3_VECTORS',
        s3VectorsConfiguration: { indexArn: this.vectorIndex.attrIndexArn },
      },
    });
    // The role's inline policy is a separate resource: wait for it, or Bedrock validates the
    // storage access before the permissions exist.
    this.knowledgeBase.node.addDependency(this.role);

    this.dataSource = new bedrock.CfnDataSource(this, 'DataSource', {
      name: `${name}-s3`,
      knowledgeBaseId: this.knowledgeBase.attrKnowledgeBaseId,
      // RETAIN keeps the vectors when only the data source is removed; DELETE (the Bedrock default)
      // removes them so the vector index can be deleted with the stack.
      dataDeletionPolicy: props.removalPolicy === RemovalPolicy.RETAIN ? 'RETAIN' : 'DELETE',
      dataSourceConfiguration: {
        type: 'S3',
        s3Configuration: {
          bucketArn: props.sourceBucket.bucketArn,
          inclusionPrefixes: [prefix],
        },
      },
    });

    for (const resource of [this.vectorBucket, this.vectorIndex, this.role, this.knowledgeBase, this.dataSource]) {
      resource.applyRemovalPolicy(props.removalPolicy);
    }
  }
}
