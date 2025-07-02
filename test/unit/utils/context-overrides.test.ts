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
});