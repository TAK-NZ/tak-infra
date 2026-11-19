# CHANGELOG

## Emoji Cheatsheet
- :pencil2: doc updates
- :bug: when fixing a bug
- :rocket: when making general improvements
- :white_check_mark: when adding tests
- :arrow_up: when upgrading dependencies
- :tada: when adding new features

## Version History

### Pending Release
- :bug: TAK Server could not start on a new database. The schema migrations (V7 onwards) call PostGIS functions such as `AddGeometryColumn` but nothing installed PostGIS, so `SchemaManager upgrade` failed with `function addgeometrycolumn(...) does not exist` and the ECS circuit breaker rolled the stack back. Existing environments were unaffected because their databases already had PostGIS. `start-tak.sh` now installs the extensions with `psql` (`CREATE EXTENSION IF NOT EXISTS postgis`, then `fuzzystrmatch`, `postgis_tiger_geocoder` and `postgis_topology` best effort) while `SchemaManager validate` reports the database is not initialized. It is idempotent, and a PostGIS failure stops the task with a clear message. `SchemaManager SetupRds` (the first fix, #183) does not work on Aurora PostgreSQL 18: it sends all its statements as one batch, and `alter schema tiger owner to rds_superuser` is rejected (`cannot alter ownership to "rds_superuser"`), which rolled back `create extension postgis` with it. Found on the first deploy to a new Aurora cluster (Auckland, ap-southeast-6). Verified against local Postgres with the real `SchemaManager.jar`; not yet verified on Aurora.
- :bug: Skip Bedrock knowledge bases in regions where the service does not exist (`BEDROCK_KB_UNSUPPORTED_REGIONS`, today `ap-southeast-6`), with a synth warning, instead of failing the deploy on `AWS::Bedrock::KnowledgeBase`. Fixes #179. Set `bedrock.knowledgeBases` to `[]` to silence the warning.
- :white_check_mark: Tests for the skip, the warning, and the unchanged behaviour in a supported region.
- :rocket: `scripts/bedrock/setup-bedrock-agent.py` warns when a knowledge base document in `s3://<bucket>/bedrock-kb/<kb-name>/` differs from the file of the same name in `scripts/bedrock/` (`fire_stations.txt`, `nzem-iconset.txt`, `cot-types.txt`) and prints the `aws s3 cp` and ingestion commands. Found the hard way: Test still had an old `nzem-iconset.txt` without icon folders, so the agent placed markers with an icon path that does not exist and the marker showed as a plain circle. Only files present on both sides are compared. It does not stop the run.
- :bug: `scripts/bedrock/setup-bedrock-agent.py`: swap knowledge bases one name at a time (detach the old one, then attach its replacement). An agent can have at most 2 knowledge bases (quota `indexes-per-agent`), so attaching both new ones first failed for the Demo NZDF SENTINEL agent, which has two.
- :rocket: TAK-GPT plugin: new optional bot setting `knowledgeBaseResults` (used together with `knowledgeBaseId`, or `knowledgeBaseIds` for an agent with several knowledge bases, in agent mode) sets how many chunks the agent retrieves per knowledge base search, sent as `numberOfResults` in the `InvokeAgent` session state on every call of a RETURN_CONTROL loop. Unset keeps the Bedrock default of 5, so existing bots are unchanged. S3 Vectors search is approximate (95 to 96% of the exact top 5 on the 37 benchmark questions, and the single best chunk missing for 2 of them), which cost the S3 Vectors knowledge base about 9% of supported facts at 5 results (59 against 65 for the old OpenSearch one). At 8 results it is ahead (70). On the Test agent, the "traffic-related incident codes" question lost its Police codes at 5 results and got them back at 8. Needs a TAK Server image rebuild to take effect.
- :tada: Bedrock Knowledge Bases move into CDK on Amazon S3 Vectors (#158). New `BedrockKnowledgeBase` construct creates, per name in the new `bedrock.knowledgeBases` setting (default `["nema-cdem"]`; override `--context bedrockKnowledgeBases=nema-cdem,nzdf`): a vector bucket and index (1024 dimensions, float32, cosine), the service role (reads only `bedrock-kb/<name>/` in the TAK Images bucket, decrypts with its key, invokes Titan Embed Text v2, and uses only its own index), the knowledge base `<name>-s3v` and its S3 data source. IDs are stack outputs (`BedrockKb<Name>Id`, `BedrockKb<Name>DataSourceId`). It replaces the OpenSearch Serverless collection that the setup script created: that collection billed about $340 (Test) and $400 (Demo) a month around the clock for almost no search traffic. Spikes in Test: retrieval 0.35 s with no cold start (NextGen OpenSearch with minimum 0 OCU had an 11 to 14 s first query), and the same number of answer-key facts in the retrieved chunks as the current knowledge base (63 against 65 of 282 on the 37 benchmark questions; within noise). Nothing changes for a running environment until the stack is deployed and the setup script is run; the old collection keeps billing until it is deleted (steps in `scripts/bedrock/README.md`). Not yet verified: answer quality through the agent, and Demo's own knowledge bases.
- :rocket: `scripts/bedrock/setup-bedrock-agent.py` no longer creates the OpenSearch collection, index, knowledge base role or knowledge base. It reads the knowledge base ID from the TakInfra stack outputs and stops with instructions if it is missing, syncs the knowledge base if it has never been ingested (waiting for the job to finish before the agent uses it), and swaps the old OpenSearch knowledge base of the same name for the new one on the agent. Knowledge bases with other names stay attached, and `--extra-kb-name` attaches more than one (the Demo NZDF SENTINEL agent uses `nzdf` and `nema-cdem`). Existing environments keep working until the script is run again.
- :rocket: Demo pipeline: pass `bedrockKnowledgeBases=nema-cdem,nzdf` so Demo gets both of its knowledge bases.
- :white_check_mark: Tests for the knowledge base construct (index, storage, IAM scope, removal policy, name validation), the list override and the stack wiring.
- :rocket: Database construct: set `log_statement` to `ddl` (was `all`). The TAK Server database wrote about 2 MB/s of PostgreSQL log (170 to 225 GB a day, a new 100 MB file every ~50 s) because every CoT message is an `INSERT INTO cot_router` that `all` logs together with its parameters (callsigns, positions). That log load costs CPU and local storage on the provisioned `db.t4g.large`, which has no CPU credit headroom. The log was never exported (`enableCloudWatchLogs` is off) and is kept 3 days locally. Schema changes are still logged, and statements over 1 s are still logged through `log_min_duration_statement`. The parameter is dynamic, so there is no reboot. Applies to every cluster this construct creates, including `prod`. To debug a query problem, set `log_statement` back to `all` or `mod` on the cluster parameter group for a short time.
- :white_check_mark: Test for the statement-logging parameters.
- :arrow_up: Bump TAK Server from 5.8-RELEASE-79 to 5.8-RELEASE-103 (`takserver-docker-5.8-RELEASE-103.zip`): `takserver.version` in both profiles, the fallback `ARG TAK_VERSION` in both Dockerfiles, and the README and docs examples (which still said 5.4-RELEASE-19). Checked against 79: the zip passes `unzip -t` and its layout is identical apart from the version in one jar name; `configureInDocker.sh` is byte-identical, so `patch-jvm-flags.py` applies unchanged; the SchemaManager jar has the same entries (no new migration files by name); CoreConfig template selection keys on major.minor (5.8), so it is unchanged; and the tak-gpt plugin compiles against the 103 jars. Not tested: a running 103 server, the content of the schema migrations, or ATAK client compatibility. The pipeline downloads the zip from the BaseInfra TAK Images bucket (present in Demo); Test builds from the zip in the repo root. Deploying restarts TAK Server, and the Dockerfiles feed the image content hash, so the next pipeline run builds a new image.
- :pencil2: Correct the `npm audit` policy note in `.npmrc`. After upgrading to the latest CDK, `npm audit` still reports 38 findings (36 high, 2 moderate) from two root causes with no available fix: picomatch <= 4.0.7 (no patched release exists; dev-only, via the jest toolchain; all 36 high) and the minimatch copy bundled inside aws-cdk-lib (upstream fixed it in aws/aws-cdk#39595 on 2026-11-13, after 2.277.0 was cut; the only findings in production dependencies). The gate stays at `audit-level=critical`, so the exit code is 0. A withdrawn deepmerge advisory was removed from the note.
- :arrow_up: Upgrade aws-cdk-lib 2.275.0 -> 2.277.0 and the aws-cdk CLI 2.1147.0 -> 2.1148.1 (the latest releases; constructs 10.8.1 is already the latest). Synthesising the same source with the old and the new CDK differs only in asset content hashes, the CDKMetadata blob and an update timestamp: no resource, IAM or property changes come from the upgrade itself.
- :rocket: Turn off the TAK Server CloudWatch metrics export (`takserver.enableCloudWatchMetrics` is now `false` in both profiles). It published about 600 billed custom metrics (about $180 a month per environment) that no alarm, dashboard or code reads. Set it back to `true` to re-enable: the API JVM keeps its Netty TLS workaround (`patch-jvm-flags.py`, unchanged on purpose), so the exporter works again without other changes. Redeploying restarts the TAK Server task.
- :rocket: Move the `dev-test` TAK Server database from Aurora Serverless v2 to a provisioned `db.t4g.large` on Aurora I/O-Optimized storage. Measured on the live Test and Demo clusters over 30 days, the provisioned cost is about $149 and $239 a month, against $395 and $616 on standard storage with per-request I/O charges. The `prod` profile is unchanged. This restarts the database writer once on deploy; watch `FreeableMemory` and `CPUCreditBalance` afterwards, and load-test the CoT cleanup if the instance looks tight.
- :tada: Database construct: new `database.ioOptimized` setting (tri-state: unset leaves the cluster's storage type untouched, `true` is I/O-Optimized, `false` is Standard), and provisioned classes `db.r6g`, `db.r7g` and `db.r8g` (`large` and up) are now honoured instead of being silently mapped to a T4G. An unrecognised class still falls back to `db.t4g.large` or `db.t4g.medium`, now with a synth warning.
- :bug: Database construct: switch off the RDS Data API on provisioned clusters. AWS does not support it on T-class instances, and the existing Serverless v2 clusters have it enabled, which makes the change to a provisioned class fail and roll back.
- :bug: Demo pipeline: the prod-window database override now uses `db.t4g.large` and `ioOptimized=true` (it forced `db.serverless`, which would flip the database back on every run), and passes `ioOptimized=true` for the `[use-prod-db]` path too. AWS allows moving from I/O-Optimized back to Standard only once every 30 days.
- :white_check_mark: Tests for the Data API flag, storage type, instance-class resolution, the `ioOptimized` override and the new defaults.

### v2.2.0

- :rocket: Move ECS service from public to private subnet. As a result disable assignment of public IP for the task itself. External connectivity will be solely via the NLB - which is in the public subnet.


### v2.1.0

- :rocket: Moves Let's Encrypt cert requests via certbot into an asynchronous script that does not block the Docker entrypoint.

### v2.0.0

- :tada: Split stack into ELB/DB components and ECS Service for more reliable DNS/Service creation

### v1.5.0

- :rocket: Use a local TAK Server bundle is available & fallback to S3 Bucket

### v1.4.0

- :rocket: Improvements to Certificate Issuance

### v1.3.2

- :bug: Check for JKS attributes before validating

### v1.3.1

- :rocket: Rename SG to reference ECS instead of EC2

### v1.3.0

- :rocket: Update TAK Server version to 5.4

### v1.2.0 (@chriselsen :tada:)

- Bumped up the PostgreSQL version
- Changed filesystem layout to adopt to release 5.3. Everything is in /opt/tak and only /opt/tak/certs/files is persistent.
- Added port 80 for Letsencrypt
- Added workflow to chose between Letsencrypt Prod and Test cert
- TAK admin.p12 cert is persisted into Secrets Manager
- Various other small fixes

### v1.1.0

- :bug: Lock Service Traffic to ELB

### v1.0.1

- :rocket: Removed unused cloud deps

### v1.0.0

- :rocket: Initial Release

