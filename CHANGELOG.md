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

