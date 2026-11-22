/**
 * Validity periods and PKCS#12 profile of the first-boot PKI (#189). Defaults follow #171:
 * Root CA 20 years, Intermediate CA 10 years, Enrollment CA 3 years, server and admin cert 1 year.
 * The same ordering and range checks run in `pki-bootstrap.sh`; doing them at synth time means a bad
 * value fails the deploy instead of the first start of the task.
 */
export interface PkiValidityConfig {
  rootDays?: number;
  intermediateDays?: number;
  enrollmentCaDays?: number;
  serverCertDays?: number;
  adminCertDays?: number;
  /** The server certificate is rotated when this many days or fewer are left (#131). Must be smaller than `serverCertDays`. */
  serverCertRenewDays?: number;
  /** The admin certificate is rotated when this many days or fewer are left (#132). Must be smaller than `adminCertDays`. */
  adminCertRenewDays?: number;
  /** Days after an admin certificate rotation until the copies of the previous admin key are deleted (#132). */
  adminCertGraceDays?: number;
}

export type P12Profile = 'compat3des' | 'aes256';

export const PKI_DEFAULT_VALIDITY_DAYS = {
  rootDays: 7300,
  intermediateDays: 3650,
  enrollmentCaDays: 1095,
  serverCertDays: 365,
  adminCertDays: 365,
  serverCertRenewDays: 60,
  adminCertRenewDays: 60,
  adminCertGraceDays: 7,
} as const;

export const P12_PROFILES: readonly P12Profile[] = ['compat3des', 'aes256'];

export function resolvePkiValidity(config: PkiValidityConfig = {}): Required<PkiValidityConfig> {
  const v = { ...PKI_DEFAULT_VALIDITY_DAYS, ...Object.fromEntries(Object.entries(config).filter(([, x]) => x !== undefined)) } as Required<PkiValidityConfig>;
  for (const [name, days] of Object.entries(v)) {
    if (!Number.isInteger(days) || days < 1 || days > 36500) {
      throw new Error(`Invalid pki.kmsCa.validity.${name} ${days}: must be a whole number of days from 1 to 36500`);
    }
  }
  if (!(v.rootDays > v.intermediateDays && v.intermediateDays > v.enrollmentCaDays &&
        v.enrollmentCaDays >= v.serverCertDays && v.enrollmentCaDays >= v.adminCertDays)) {
    throw new Error(
      'pki.kmsCa.validity: a certificate must not outlive its issuer (root > intermediate > enrollment CA >= server and admin), got ' +
      `${v.rootDays}/${v.intermediateDays}/${v.enrollmentCaDays}/${v.serverCertDays}/${v.adminCertDays}`
    );
  }
  if (!(v.serverCertRenewDays < v.serverCertDays)) {
    throw new Error(
      `pki.kmsCa.validity.serverCertRenewDays (${v.serverCertRenewDays}) must be smaller than serverCertDays (${v.serverCertDays}), ` +
      'or every new server certificate would be rotated again at once'
    );
  }
  if (!(v.adminCertRenewDays < v.adminCertDays)) {
    throw new Error(
      `pki.kmsCa.validity.adminCertRenewDays (${v.adminCertRenewDays}) must be smaller than adminCertDays (${v.adminCertDays}), ` +
      'or every new admin certificate would be rotated again at once'
    );
  }
  return v;
}

export function validateP12Profile(profile: string | undefined): P12Profile {
  const p = profile ?? 'compat3des';
  if (!(P12_PROFILES as readonly string[]).includes(p)) {
    throw new Error(`Invalid pki.kmsCa.p12Profile '${p}': use ${P12_PROFILES.join(' or ')}`);
  }
  return p as P12Profile;
}
