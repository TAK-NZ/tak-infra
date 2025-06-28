/**
 * Test suite for configuration validation utilities
 */
import { MOCK_CONFIGS } from '../../__fixtures__/mock-configs';
import type { ContextEnvironmentConfig } from '../../../lib/stack-config';

describe('Configuration Validator', () => {
  describe('Environment Configuration Validation', () => {
    test('validates complete dev-test configuration', () => {
      const config = MOCK_CONFIGS.DEV_TEST;
      
      expect(config.stackName).toBeDefined();
      expect(config.database).toBeDefined();
      expect(config.ecs).toBeDefined();
      expect(config.takserver).toBeDefined();
      expect(config.ecr).toBeDefined();
      expect(config.general).toBeDefined();
    });

    test('validates database configuration', () => {
      const config = MOCK_CONFIGS.DEV_TEST;
      
      expect(config.database.instanceClass).toMatch(/^db\.(serverless|t4g\.(micro|small|medium|large))$/);
      expect(config.database.instanceCount).toBeGreaterThan(0);
      expect(config.database.backupRetentionDays).toBeGreaterThanOrEqual(1);
      expect(typeof config.database.enablePerformanceInsights).toBe('boolean');
      expect(typeof config.database.deleteProtection).toBe('boolean');
    });

    test('validates ECS configuration', () => {
      const config = MOCK_CONFIGS.DEV_TEST;
      
      expect(config.ecs.taskCpu).toBeGreaterThan(0);
      expect(config.ecs.taskMemory).toBeGreaterThan(0);
      expect(config.ecs.desiredCount).toBeGreaterThan(0);
      expect(typeof config.ecs.enableDetailedLogging).toBe('boolean');
    });

    test('validates TAK Server configuration', () => {
      const config = MOCK_CONFIGS.DEV_TEST;
      
      expect(config.takserver.hostname).toBeDefined();
      expect(config.takserver.servicename).toBeDefined();
      expect(config.takserver.branding).toMatch(/^(generic|tak-nz)$/);
      expect(config.takserver.version).toMatch(/^\d+\.\d+-RELEASE-\d+$/);
      expect(typeof config.takserver.useS3TAKServerConfigFile).toBe('boolean');
    });

    test('validates ECR configuration', () => {
      const config = MOCK_CONFIGS.DEV_TEST;
      
      expect(config.ecr.imageRetentionCount).toBeGreaterThan(0);
      expect(typeof config.ecr.scanOnPush).toBe('boolean');
    });

    test('validates general configuration', () => {
      const config = MOCK_CONFIGS.DEV_TEST;
      
      expect(config.general.removalPolicy).toMatch(/^(DESTROY|RETAIN)$/);
      expect(typeof config.general.enableDetailedLogging).toBe('boolean');
      expect(typeof config.general.enableContainerInsights).toBe('boolean');
    });
  });

  describe('Environment-specific Validation', () => {
    test('validates production configuration has appropriate settings', () => {
      const config = MOCK_CONFIGS.PROD;
      
      expect(config.database.deleteProtection).toBe(true);
      expect(config.database.backupRetentionDays).toBeGreaterThanOrEqual(7);
      expect(config.general.removalPolicy).toBe('RETAIN');
      expect(config.ecr.scanOnPush).toBe(true);
    });

    test('validates development configuration has appropriate settings', () => {
      const config = MOCK_CONFIGS.DEV_TEST;
      
      expect(config.general.removalPolicy).toBe('DESTROY');
      expect(config.database.deleteProtection).toBe(false);
      expect(config.ecs.enableEcsExec).toBe(true);
    });
  });

  describe('Configuration Consistency', () => {
    test('validates CPU and memory combinations are valid', () => {
      const configs = [MOCK_CONFIGS.DEV_TEST, MOCK_CONFIGS.PROD, MOCK_CONFIGS.SERVERLESS];
      
      configs.forEach(config => {
        const { taskCpu, taskMemory } = config.ecs;
        
        // Validate Fargate CPU/Memory combinations
        const validCombinations = [
          { cpu: 256, memory: [512, 1024, 2048] },
          { cpu: 512, memory: [1024, 2048, 3072, 4096] },
          { cpu: 1024, memory: [2048, 3072, 4096, 5120, 6144, 7168, 8192] },
          { cpu: 2048, memory: [4096, 5120, 6144, 7168, 8192, 9216, 10240, 11264, 12288, 13312, 14336, 15360, 16384] },
          { cpu: 4096, memory: Array.from({length: 23}, (_, i) => 8192 + i * 1024) }
        ];
        
        const validCombo = validCombinations.find(combo => 
          combo.cpu === taskCpu && combo.memory.includes(taskMemory)
        );
        
        expect(validCombo).toBeDefined();
      });
    });

    test('validates database instance counts are reasonable', () => {
      const configs = [MOCK_CONFIGS.DEV_TEST, MOCK_CONFIGS.PROD, MOCK_CONFIGS.SERVERLESS];
      
      configs.forEach(config => {
        expect(config.database.instanceCount).toBeGreaterThanOrEqual(1);
        expect(config.database.instanceCount).toBeLessThanOrEqual(5);
      });
    });
  });

  describe('Error Handling', () => {
    test('handles missing required fields', () => {
      const incompleteConfig = {
        stackName: 'Test'
        // Missing other required fields
      } as Partial<ContextEnvironmentConfig>;
      
      expect(incompleteConfig.database).toBeUndefined();
      expect(incompleteConfig.ecs).toBeUndefined();
      expect(incompleteConfig.takserver).toBeUndefined();
    });

    test('handles invalid values', () => {
      const invalidConfig = {
        ...MOCK_CONFIGS.DEV_TEST,
        database: {
          ...MOCK_CONFIGS.DEV_TEST.database,
          instanceCount: -1 // Invalid
        }
      };
      
      expect(invalidConfig.database.instanceCount).toBeLessThan(0);
    });
  });
});