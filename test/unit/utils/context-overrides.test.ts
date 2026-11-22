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
  describe('pki.kmsCa (#136)', () => {
    const appWith = (ctx: Record<string, string>) => ({ node: { tryGetContext: (k: string) => ctx[k] } }) as any;
    const withKmsCa = (kmsCa?: any) => ({ ...MOCK_CONFIGS.DEV_TEST, pki: kmsCa ? { kmsCa } : undefined });

    test('stays undefined when neither the config nor the command line mention it', () => {
      expect(applyContextOverrides(appWith({}), withKmsCa()).pki).toBeUndefined();
    });

    test('the command line can switch it on', () => {
      const result = applyContextOverrides(appWith({ pkiKmsCaEnabled: 'true', pkiEnvironmentLabel: 'Try' }), withKmsCa());
      expect(result.pki?.kmsCa).toMatchObject({ enabled: true, environmentLabel: 'Try' });
    });

    test('keeps the config values when there are no overrides', () => {
      const base = { enabled: true, environmentLabel: 'Try', rootCaNumbers: [1], intermediateCaNumbers: [1, 2] };
      expect(applyContextOverrides(appWith({}), withKmsCa(base)).pki?.kmsCa).toMatchObject(base);
    });

    test('the command line can add the next generation', () => {
      const base = { enabled: true, environmentLabel: 'Try', intermediateCaNumbers: [1] };
      const result = applyContextOverrides(appWith({ pkiIntermediateCaNumbers: '1, 2' }), withKmsCa(base));
      expect(result.pki?.kmsCa?.intermediateCaNumbers).toEqual([1, 2]);
    });

    test('the command line can switch it off', () => {
      const base = { enabled: true, environmentLabel: 'Try' };
      expect(applyContextOverrides(appWith({ pkiKmsCaEnabled: 'false' }), withKmsCa(base)).pki?.kmsCa?.enabled).toBe(false);
    });

    test('the command line can set the p12 profile and the validities', () => {
      const base = { enabled: true, environmentLabel: 'Try', validity: { serverCertDays: 300 } };
      const result = applyContextOverrides(appWith({ pkiP12Profile: 'aes256', pkiRootDays: '5000', pkiAdminCertDays: '100' }), withKmsCa(base));
      expect(result.pki?.kmsCa?.p12Profile).toBe('aes256');
      expect(result.pki?.kmsCa?.validity).toEqual({ serverCertDays: 300, rootDays: 5000, adminCertDays: 100 });
    });

    test('the command line can set the server certificate renewal threshold', () => {
      const base = { enabled: true, environmentLabel: 'Try' };
      const result = applyContextOverrides(appWith({ pkiServerCertRenewDays: '45' }), withKmsCa(base));
      expect(result.pki?.kmsCa?.validity).toEqual({ serverCertRenewDays: 45 });
    });
    test('the command line can set the admin certificate renewal threshold and grace period', () => {
      const result = applyContextOverrides(appWith({ pkiAdminCertRenewDays: '45', pkiAdminCertGraceDays: '3' }), withKmsCa({ enabled: true, environmentLabel: 'Try' }));
      expect(result.pki?.kmsCa?.validity).toEqual({ adminCertRenewDays: 45, adminCertGraceDays: 3 });
    });
    test('the command line can set the rotation settings', () => {
      const result = applyContextOverrides(appWith({ pkiRotationBufferDays: '30', pkiEnrollmentCaRotationDays: '300', pkiRotationRequireApproval: 'cut, retire' }), withKmsCa({ enabled: true, environmentLabel: 'Try' }));
      expect(result.pki?.kmsCa?.rotation).toEqual({ bufferDays: 30, enrollmentCaRotationDays: 300, requireApproval: ['cut', 'retire'] });
    });
    test('an empty approval list switches the approval off', () => {
      const result = applyContextOverrides(appWith({ pkiRotationRequireApproval: '' }), withKmsCa({ enabled: true, environmentLabel: 'Try' }));
      expect(result.pki?.kmsCa?.rotation?.requireApproval).toEqual([]);
    });
    test('the command line can set the info email', () => {
      const result = applyContextOverrides(appWith({ pkiInfoEmail: 'info@example.org' }), withKmsCa({ enabled: true, environmentLabel: 'Try' }));
      expect(result.pki?.kmsCa?.infoEmail).toBe('info@example.org');
    });

    test('no validity is created when nothing sets one', () => {
      const result = applyContextOverrides(appWith({}), withKmsCa({ enabled: true, environmentLabel: 'Try' }));
      expect(result.pki?.kmsCa?.validity).toBeUndefined();
    });

    test('enabled without an environment label is an error', () => {
      expect(() => applyContextOverrides(appWith({ pkiKmsCaEnabled: 'true' }), withKmsCa())).toThrow(/environmentLabel/);
    });

    test('a number list with a non-number is an error', () => {
      expect(() => applyContextOverrides(appWith({ pkiRootCaNumbers: '1,x', pkiEnvironmentLabel: 'Try' }), withKmsCa()))
        .toThrow(/Invalid number 'x'/);
    });
  });
});
