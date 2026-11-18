/**
 * Test suite for context overrides utility
 */
import { applyContextOverrides } from '../../../lib/utils/context-overrides';
import { MOCK_CONFIGS } from '../../__fixtures__/mock-configs';

describe('Context Overrides', () => {
  test('should handle CLI context overrides with string values', () => {
    // Simulate CLI context where all values are strings
    const mockApp = {
      node: {
        tryGetContext: (key: string) => {
          const cliValues: Record<string, string> = {
            'backupRetentionDays': '7',
            'instanceCount': '2',
            'enablePerformanceInsights': 'false',
            'deleteProtection': 'true',
            'monitoringInterval': '60'
          };
          return cliValues[key];
        }
      }
    } as any;

    const result = applyContextOverrides(mockApp, MOCK_CONFIGS.DEV_TEST);
    
    expect(typeof result.database.backupRetentionDays).toBe('number');
    expect(result.database.backupRetentionDays).toBe(7);
    expect(typeof result.database.instanceCount).toBe('number');
    expect(result.database.instanceCount).toBe(2);
    expect(typeof result.database.enablePerformanceInsights).toBe('boolean');
    expect(result.database.enablePerformanceInsights).toBe(false);
    expect(typeof result.database.deleteProtection).toBe('boolean');
    expect(result.database.deleteProtection).toBe(true);
    expect(typeof result.database.monitoringInterval).toBe('number');
    expect(result.database.monitoringInterval).toBe(60);
  });

  describe('database.ioOptimized', () => {
    const appWith = (values: Record<string, unknown>) => ({
      node: { tryGetContext: (key: string) => values[key] }
    } as any);

    test('"true" from the CLI turns it on', () => {
      const result = applyContextOverrides(appWith({ ioOptimized: 'true' }), MOCK_CONFIGS.DEV_TEST);
      expect(result.database.ioOptimized).toBe(true);
    });

    test('"false" from the CLI turns it off explicitly (not the same as unset)', () => {
      const result = applyContextOverrides(appWith({ ioOptimized: 'false' }), MOCK_CONFIGS.DEV_TEST);
      expect(result.database.ioOptimized).toBe(false);
    });

    test('no override keeps the base config value', () => {
      const base = { ...MOCK_CONFIGS.DEV_TEST, database: { ...MOCK_CONFIGS.DEV_TEST.database, ioOptimized: true } };
      expect(applyContextOverrides(appWith({}), base).database.ioOptimized).toBe(true);
    });

    test('stays unset when neither the base config nor the CLI sets it (the prod profile case)', () => {
      expect(applyContextOverrides(appWith({}), MOCK_CONFIGS.PROD).database.ioOptimized).toBeUndefined();
    });
  });

  describe('bedrock.knowledgeBases', () => {
    const appWith = (values: Record<string, unknown>) => ({
      node: { tryGetContext: (key: string) => values[key] }
    } as any);
    const withKbs = (knowledgeBases?: string[]) => ({ ...MOCK_CONFIGS.DEV_TEST, bedrock: { knowledgeBases } });

    test('keeps the configured list when there is no override', () => {
      const result = applyContextOverrides(appWith({}), withKbs(['nema-cdem']));
      expect(result.bedrock?.knowledgeBases).toEqual(['nema-cdem']);
    });

    test('a comma-separated override replaces the list (spaces and empty items dropped)', () => {
      const result = applyContextOverrides(appWith({ bedrockKnowledgeBases: 'nema-cdem, nzdf,' }), withKbs(['nema-cdem']));
      expect(result.bedrock?.knowledgeBases).toEqual(['nema-cdem', 'nzdf']);
    });

    test('an empty override switches knowledge bases off', () => {
      const result = applyContextOverrides(appWith({ bedrockKnowledgeBases: '' }), withKbs(['nema-cdem']));
      expect(result.bedrock?.knowledgeBases).toEqual([]);
    });

    test('is unset when neither config nor override sets it', () => {
      const result = applyContextOverrides(appWith({}), MOCK_CONFIGS.DEV_TEST);
      expect(result.bedrock?.knowledgeBases).toBeUndefined();
    });
  });
});
