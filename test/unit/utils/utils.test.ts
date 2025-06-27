/**
 * Test suite for utility functions
 */
import { validateEnvType, validateStackName, getGitSha } from '../../../lib/utils';

describe('Utility Functions', () => {
  describe('validateEnvType', () => {
    test('should accept valid environment types', () => {
      expect(() => validateEnvType('prod')).not.toThrow();
      expect(() => validateEnvType('dev-test')).not.toThrow();
    });

    test('should reject invalid environment types', () => {
      expect(() => validateEnvType('invalid')).toThrow('Invalid envType: invalid. Must be \'prod\' or \'dev-test\'');
      expect(() => validateEnvType('development')).toThrow();
      expect(() => validateEnvType('')).toThrow();
    });
  });

  describe('validateStackName', () => {
    test('should accept valid stack names', () => {
      expect(() => validateStackName('MyStack')).not.toThrow();
      expect(() => validateStackName('TAK-Demo-TakInfra')).not.toThrow();
    });

    test('should reject invalid stack names', () => {
      expect(() => validateStackName(undefined)).toThrow('stackName is required. Use --context stackName=YourStackName');
      expect(() => validateStackName('')).toThrow();
    });
  });

  describe('getGitSha', () => {
    test('should return a string', () => {
      const result = getGitSha();
      expect(typeof result).toBe('string');
      expect(result.length).toBeGreaterThan(0);
    });

    test('should return git sha or unknown', () => {
      const result = getGitSha();
      expect(result === 'unknown' || result.length === 40).toBe(true);
    });
  });
});