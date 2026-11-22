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

/**
 * Settings of the rotation orchestrator (#171, `pki-rotate.sh`). W, the window in which every phone must get a
 * new certificate before trust is removed, is `clientCertDays + bufferDays` (455 days by default).
 */
export interface PkiRotationConfig {
  clientCertDays?: number;
  bufferDays?: number;
  enrollmentCaRotationDays?: number;
  requireApproval?: string[];
}
export const PKI_DEFAULT_ROTATION = {
  clientCertDays: 365,
  bufferDays: 90,
  enrollmentCaRotationDays: 365,
  requireApproval: ['retire'],
} as const;
/** Steps that exist in the rotation scenarios; an approval can only be required for one of these. */
export const PKI_ROTATION_STEP_NAMES = ['bridge', 'cut', 'retire', 'switch'] as const;
export function resolvePkiRotation(
  config: PkiRotationConfig = {},
  validity: Required<PkiValidityConfig> = resolvePkiValidity(),
): Required<PkiRotationConfig> & { windowDays: number } {
  const r = { ...PKI_DEFAULT_ROTATION, ...Object.fromEntries(Object.entries(config).filter(([, x]) => x !== undefined)) } as Required<PkiRotationConfig>;
  for (const name of ['clientCertDays', 'bufferDays', 'enrollmentCaRotationDays'] as const) {
    if (!Number.isInteger(r[name]) || r[name] < 1 || r[name] > 36500) {
      throw new Error(`Invalid pki.kmsCa.rotation.${name} ${r[name]}: must be a whole number of days from 1 to 36500`);
    }
  }
  for (const step of r.requireApproval) {
    if (!(PKI_ROTATION_STEP_NAMES as readonly string[]).includes(step)) {
      throw new Error(`Invalid pki.kmsCa.rotation.requireApproval '${step}': use ${PKI_ROTATION_STEP_NAMES.join(', ')}`);
    }
  }
  const windowDays = r.clientCertDays + r.bufferDays;
  // A client certificate is valid clientCertDays and may be issued on the last day before a rotation, so an
  // Enrollment CA must live for its rotation period plus a whole client certificate lifetime plus the buffer
  if (validity.enrollmentCaDays < r.enrollmentCaRotationDays + windowDays) {
    throw new Error(
      `pki.kmsCa: the Enrollment CA validity (${validity.enrollmentCaDays} days) must be at least its rotation period ` +
      `(${r.enrollmentCaRotationDays}) plus the window W (${windowDays} = client certificate ${r.clientCertDays} + buffer ${r.bufferDays})`
    );
  }
  // The Intermediate CA needs two windows (bridge and cut) plus a year of margin before it expires
  if (validity.intermediateDays < 2 * windowDays + 365) {
    throw new Error(
      `pki.kmsCa: the Intermediate CA validity (${validity.intermediateDays} days) must be at least 2 x W + 365 (${2 * windowDays + 365}) ` +
      'for a two-phase rotation to fit'
    );
  }
  if (validity.rootDays < windowDays + 365) {
    throw new Error(`pki.kmsCa: the Root CA validity (${validity.rootDays} days) must be at least W + 365 (${windowDays + 365})`);
  }
  return { ...r, windowDays };
}
