/**
 * Test suite for the CA naming rules (issue #171)
 */
import {
  caCommonName,
  caKeyLabel,
  caSlug,
  environmentSlug,
  validateCaNumber,
  validateEnvironmentLabel,
} from '../../../lib/utils/pki-names';

describe('pki-names', () => {
  test('common names follow `TAK.NZ <Env> <Tier> NN`', () => {
    expect(caCommonName('Try', 'root', 1)).toBe('TAK.NZ Try Root CA 01');
    expect(caCommonName('Try', 'intermediate', 1)).toBe('TAK.NZ Try Intermediate CA 01');
    expect(caCommonName('Prod', 'intermediate', 12)).toBe('TAK.NZ Prod Intermediate CA 12');
  });

  test('slugs and labels contain no spaces', () => {
    expect(caSlug('Try', 'root', 1)).toBe('tak-nz-try-root-ca-01');
    expect(caSlug('Dev Test', 'intermediate', 2)).toBe('tak-nz-dev-test-intermediate-ca-02');
    expect(caKeyLabel('intermediate', 3)).toBe('intermediate-ca-03');
    expect(environmentSlug('Dev Test')).toBe('dev-test');
  });

  test('PKCS#11 labels stay within 32 characters', () => {
    expect(caKeyLabel('intermediate', 99).length).toBeLessThanOrEqual(32);
  });

  test.each([0, -1, 100, 1.5, NaN])('rejects CA number %p', n => {
    expect(() => validateCaNumber(n)).toThrow(/CA number/);
  });

  test.each(['', ' Try', 'Try ', 'a/b', 'Try!', 'x'.repeat(25)])('rejects environment label %p', label => {
    expect(() => validateEnvironmentLabel(label)).toThrow(/environment label/);
  });

  test.each(['Try', 'Prod', 'Dev Test', 'Demo-2', 'A'])('accepts environment label %p', label => {
    expect(() => validateEnvironmentLabel(label)).not.toThrow();
  });

  test('longest allowed label still gives a CN under 64 characters', () => {
    expect(caCommonName('x'.repeat(24), 'intermediate', 99).length).toBeLessThanOrEqual(64);
  });
});
