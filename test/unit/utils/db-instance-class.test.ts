/**
 * Test suite for resolveProvisionedInstanceClass
 */
import { resolveProvisionedInstanceClass } from '../../../lib/utils/db-instance-class';

describe('resolveProvisionedInstanceClass', () => {
  describe('supported classes are honoured exactly', () => {
    test.each([
      ['db.t4g.medium', 't4g.medium'],
      ['db.t4g.large', 't4g.large'],
      ['db.r6g.large', 'r6g.large'],
      ['db.r6g.xlarge', 'r6g.xlarge'],
      ['db.r7g.2xlarge', 'r7g.2xlarge'],
      ['db.r8g.16xlarge', 'r8g.16xlarge']
    ])('%s -> %s', (input, expected) => {
      expect(resolveProvisionedInstanceClass(input)).toEqual({ instanceType: expected, recognised: true });
    });
  });

  describe('legacy fallback keeps the old T4G behaviour and is flagged as not recognised', () => {
    test.each([
      // contains "large": old code chose T4G LARGE
      ['db.t3.large', 't4g.large'],
      ['db.m5.xlarge', 't4g.large'],
      // everything else: old code chose T4G MEDIUM
      ['db.t4g.small', 't4g.medium'],
      ['db.t3.micro', 't4g.medium'],
      ['db.r5.medium', 't4g.medium']
    ])('%s -> %s', (input, expected) => {
      expect(resolveProvisionedInstanceClass(input)).toEqual({ instanceType: expected, recognised: false });
    });
  });

  describe('is strict about what counts as a supported class', () => {
    test.each([
      'db.t4g.xlarge', // not offered for Aurora PostgreSQL on T4G
      'db.t4g.small',
      'db.r6g.medium', // r-class starts at large
      'db.r5.large', // older family, not accepted
      'db.serverless', // handled by the caller, never a provisioned class
      't4g.large', // missing the db. prefix
      'DB.T4G.LARGE', // case matters
      ' db.t4g.large', // whitespace
      'db.t4g.large ',
      'db.t4g.large;rm',
      'db.t4g.largex',
      ''
    ])('"%s" is not recognised', (input) => {
      expect(resolveProvisionedInstanceClass(input).recognised).toBe(false);
    });

    test('a recognised class never gets a db. prefix on the instance type', () => {
      expect(resolveProvisionedInstanceClass('db.r6g.large').instanceType.startsWith('db.')).toBe(false);
    });
  });
});
