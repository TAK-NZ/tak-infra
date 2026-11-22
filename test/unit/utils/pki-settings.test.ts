/**
 * Test suite for the first-boot PKI settings (#189)
 */
import { PKI_DEFAULT_ROTATION, PKI_DEFAULT_VALIDITY_DAYS, resolvePkiRotation, resolvePkiValidity, validateP12Profile } from '../../../lib/utils/pki-settings';

describe('pki-settings', () => {
  test('defaults follow #171: root 20 y, intermediate 10 y, enrollment CA 3 y, server and admin 1 y', () => {
    expect(resolvePkiValidity()).toEqual({ rootDays: 7300, intermediateDays: 3650, enrollmentCaDays: 1095, serverCertDays: 365, adminCertDays: 365, serverCertRenewDays: 60, adminCertRenewDays: 60, adminCertGraceDays: 7 });
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

  test('the renewal threshold must be smaller than the server certificate validity (a new certificate would be rotated at once)', () => {
    expect(() => resolvePkiValidity({ serverCertDays: 60 })).toThrow(/must be smaller than serverCertDays/);
    expect(() => resolvePkiValidity({ serverCertRenewDays: 365 })).toThrow(/must be smaller than serverCertDays/);
    expect(resolvePkiValidity({ serverCertDays: 30, serverCertRenewDays: 10 })).toMatchObject({ serverCertDays: 30, serverCertRenewDays: 10 });
  });
  test('the admin certificate renewal threshold must be smaller than its validity', () => {
    expect(() => resolvePkiValidity({ adminCertDays: 60 })).toThrow(/adminCertRenewDays.*must be smaller than adminCertDays/);
    expect(() => resolvePkiValidity({ adminCertRenewDays: 365 })).toThrow(/must be smaller than adminCertDays/);
    expect(resolvePkiValidity({ adminCertDays: 30, adminCertRenewDays: 10, adminCertGraceDays: 3 })).toMatchObject({ adminCertRenewDays: 10, adminCertGraceDays: 3 });
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

describe('resolvePkiRotation (#171)', () => {
  test('defaults: C 365, B 90, W 455, Enrollment CA rotated at 365 days, approval for retire', () => {
    expect(resolvePkiRotation()).toEqual({ clientCertDays: 365, bufferDays: 90, enrollmentCaRotationDays: 365, requireApproval: ['cut', 'retire'], windowDays: 455 });
    expect(PKI_DEFAULT_ROTATION.bufferDays).toBe(90);
  });
  test('W follows the client certificate validity and the buffer', () => {
    expect(resolvePkiRotation({ clientCertDays: 180, bufferDays: 30 }).windowDays).toBe(210);
  });
  test('an Enrollment CA that cannot cover its rotation period plus W is refused', () => {
    expect(() => resolvePkiRotation({ enrollmentCaRotationDays: 700 })).toThrow(/Enrollment CA validity/);
    expect(() => resolvePkiRotation({}, resolvePkiValidity({ enrollmentCaDays: 800, serverCertDays: 365, adminCertDays: 365 }))).toThrow(/Enrollment CA validity \(800 days\)/);
  });
  test('an Intermediate CA that cannot fit a two-phase rotation is refused', () => {
    expect(() => resolvePkiRotation({}, resolvePkiValidity({ intermediateDays: 1200 }))).toThrow(/Intermediate CA validity/);
  });
  test('an unknown approval step and a bad number are refused', () => {
    expect(() => resolvePkiRotation({ requireApproval: ['explode'] })).toThrow(/requireApproval/);
    expect(() => resolvePkiRotation({ bufferDays: 0 })).toThrow(/whole number of days/);
  });
});
