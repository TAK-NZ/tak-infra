/**
 * Test suite for the first-boot PKI settings (#189)
 */
import { PKI_DEFAULT_VALIDITY_DAYS, resolvePkiValidity, validateP12Profile } from '../../../lib/utils/pki-settings';

describe('pki-settings', () => {
  test('defaults follow #171: root 20 y, intermediate 10 y, enrollment CA 3 y, server and admin 1 y', () => {
    expect(resolvePkiValidity()).toEqual({ rootDays: 7300, intermediateDays: 3650, enrollmentCaDays: 1095, serverCertDays: 365, adminCertDays: 365 });
    expect(PKI_DEFAULT_VALIDITY_DAYS.rootDays).toBe(7300);
  });

  test('a partial override keeps the other defaults', () => {
    expect(resolvePkiValidity({ serverCertDays: 200 })).toMatchObject({ rootDays: 7300, serverCertDays: 200 });
  });

  test('undefined values do not erase the defaults', () => {
    expect(resolvePkiValidity({ rootDays: undefined, adminCertDays: 100 }).rootDays).toBe(7300);
  });

  test.each([
    [{ rootDays: 100, intermediateDays: 200 }],
    [{ intermediateDays: 1000 }],
    [{ enrollmentCaDays: 300 }],
    [{ serverCertDays: 2000 }],
    [{ adminCertDays: 2000 }],
  ])('a certificate that outlives its issuer is refused %j', (cfg) => {
    expect(() => resolvePkiValidity(cfg)).toThrow(/must not outlive its issuer/);
  });

  test.each([0, -5, 1.5, 36501, NaN])('rejects %p days', (n) => {
    expect(() => resolvePkiValidity({ serverCertDays: n })).toThrow(/whole number of days/);
  });

  test('p12 profile: compat3des is the default, aes256 is allowed, anything else is refused', () => {
    expect(validateP12Profile(undefined)).toBe('compat3des');
    expect(validateP12Profile('aes256')).toBe('aes256');
    expect(() => validateP12Profile('legacy-rc2')).toThrow(/Invalid pki.kmsCa.p12Profile/);
  });
});
