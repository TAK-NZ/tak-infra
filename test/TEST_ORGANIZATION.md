# Test Organization Summary

## Test Suite Structure

### 📁 **test/unit/constructs/** - CDK Construct Tests

#### **database.test.ts** - Database Construct
- **Purpose**: Tests Aurora PostgreSQL cluster configurations
- **Coverage**:
  - Serverless vs provisioned instance types
  - Error handling for missing configuration
  - Environment-specific settings (prod vs dev-test)
  - Custom engine versions and instance sizes
  - Multiple reader configurations
  - Monitoring configuration variants

#### **efs.test.ts** - EFS Construct
- **Purpose**: Tests EFS file system configuration
- **Coverage**:
  - File system creation and encryption
  - Access point configuration for TAK certs and Let's Encrypt
  - Environment-specific removal policies

#### **elb.test.ts** - Load Balancer Construct
- **Purpose**: Tests Network Load Balancer functionality
- **Coverage**:
  - Load balancer creation with dual-stack IP
  - Target group creation for all TAK ports
  - Listener configuration for TCP traffic
  - Health check configuration

#### **tak-infra-stack.test.ts** - Main Stack Integration
- **Purpose**: Tests complete stack construction and resource integration
- **Coverage**:
  - Aurora PostgreSQL cluster creation
  - EFS file system with encryption
  - Network Load Balancer configuration
  - ECS Task Definitions and Services
  - Secrets Manager integration
  - IAM roles and security groups
  - Environment-specific configurations

### 📁 **test/unit/utils/** - Utility Function Tests

#### **utils.test.ts** - Core Utility Functions
- **Purpose**: Tests core utility validation functions
- **Coverage**:
  - Environment type validation
  - Stack name validation
  - Git SHA retrieval with error handling

#### **constants.test.ts** - Constants Validation
- **Purpose**: Tests application constants
- **Coverage**:
  - Database constants validation
  - TAK Server port definitions
  - EFS port constants

#### **webtak-oidc-setup.test.ts** - WebTAK OIDC Setup Construct
- **Purpose**: Tests the WebTAK OIDC custom-resource construct
- **Coverage**:
  - Environment variable wiring (required and optional config)
  - Fallback behavior when the custom resource's `getAttString` calls fail
  - `openInNewTab` and other flag-driven template differences

## Running Tests

```bash
# Run all tests
npm test

# Run tests with coverage report
npm run test:coverage

# Run tests in watch mode
npm run test:watch

# Run specific test patterns
npm test -- --testPathPattern=constructs
npm test -- --testPathPattern=utils

# Run specific test suite
npm test -- constructs/database.test.ts
npm test -- constructs/elb.test.ts
npm test -- constructs/efs.test.ts

# Build and verify TypeScript compilation
npm run build
```

## Test Suite Summary

- **Total Test Suites**: 7
- **Total Tests**: 29

This suite was pruned against the TAK-NZ org's CDK test cleanup guide
(`CDK_TEST_CLEANUP_GUIDE.md` in the TAKTeamManager repo): a CDK test is worth
keeping only if it can fail for a real reason, not merely because config
changed on purpose or a CDK library version bumped. Coverage-percentage
figures are deliberately not tracked here as a target — `test:coverage` still
reports a number, but it's informational, not a gate. Chasing a percentage
tends to produce exactly the kind of tautological test this suite removed.

## Test Organization Principles

1. **Separation by Purpose**: Unit tests are organized by construct and utility type.
2. **Construct-Focused**: Each CDK construct has dedicated test coverage.
3. **Behavioral assertions over tautologies**: tests assert rendered
   CloudFormation properties or thrown errors, not that a hand-written mock
   fixture contains the values it was written with.
4. **Environment Variants**: Both production and dev-test configurations are validated.
5. **Verify the guard bites**: before trusting a test, its assertion should be
   checked against an actual injected bug so it goes red for the right reason.

## Recent Updates

- ✅ **Pruned** tautological tests per `CDK_TEST_CLEANUP_GUIDE.md`: deleted
  `config-validator.test.ts` (tested a `ConfigValidator` class that does not
  exist — every assertion just restated the hand-written mock fixture) and
  `constants.test.ts` (restated each exported constant's own literal value).
- ✅ **Removed** two tautological/redundant tests: `tak-infra-stack.test.ts`'s
  `should validate configuration structure`, and
  `webtak-oidc-setup.test.ts`'s `creates construct with fallback values`
  (superseded by more specific tests already in the same file).
- ✅ **Strengthened** four `database.test.ts` tests that previously only
  asserted `database.cluster` is truthy (which passes even if the construct
  ignores the config entirely) to assert the actual rendered
  `EngineVersion`, `DBInstanceClass`, reader instance count, and absence of
  monitoring properties. Verified each by temporarily reintroducing the bug
  it guards against and confirming the test goes red.
- ✅ **Fixed** the `clean` npm script to sweep compiled `.js`/`.d.ts` files in
  nested `test/` subdirectories (previously only swept the top level) and to
  not abort if `test/` doesn't exist yet.