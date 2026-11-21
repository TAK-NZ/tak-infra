/**
 * Naming rules for the CAs and their KMS keys (issue #171, "Naming").
 *
 * - CN (display name): `TAK.NZ <Env> <Tier> NN`, e.g. `TAK.NZ Try Intermediate CA 01`.
 * - The number identifies a key, not a certificate: a new key gets the next number, every
 *   certificate of the same key keeps the same subject.
 * - File names, aliases and PKCS#11 labels use a slug, never the CN with spaces.
 */

export type CaTier = 'root' | 'intermediate' | 'enrollment';

const TIER_DISPLAY: Record<CaTier, string> = {
  root: 'Root CA',
  intermediate: 'Intermediate CA',
  enrollment: 'Enrollment CA',
};

/** Longest value allowed for a CN (RFC 5280 upper bound, also `commonName_max` in TAK's config.cfg). */
export const MAX_CN_LENGTH = 64;

/** PKCS#11 token labels are limited to 32 characters. */
export const MAX_PKCS11_LABEL_LENGTH = 32;

const ENVIRONMENT_LABEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 -]{0,22}[A-Za-z0-9]$|^[A-Za-z0-9]$/;

export function validateEnvironmentLabel(label: string): void {
  if (!ENVIRONMENT_LABEL_PATTERN.test(label)) {
    throw new Error(
      `Invalid PKI environment label "${label}": use 1-24 letters, digits, spaces or hyphens, starting and ending with a letter or digit`
    );
  }
}

export function validateCaNumber(n: number): void {
  if (!Number.isInteger(n) || n < 1 || n > 99) {
    throw new Error(`Invalid CA number ${n}: must be an integer from 1 to 99`);
  }
}

function pad(n: number): string {
  validateCaNumber(n);
  return String(n).padStart(2, '0');
}

/** `Try` -> `try`, `Dev Test` -> `dev-test` */
export function environmentSlug(label: string): string {
  validateEnvironmentLabel(label);
  return label.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-');
}

/** CN for a CA key, e.g. `TAK.NZ Try Root CA 01`. */
export function caCommonName(label: string, tier: CaTier, n: number): string {
  validateEnvironmentLabel(label);
  const cn = `TAK.NZ ${label} ${TIER_DISPLAY[tier]} ${pad(n)}`;
  if (cn.length > MAX_CN_LENGTH) {
    throw new Error(`CA common name "${cn}" is longer than ${MAX_CN_LENGTH} characters`);
  }
  return cn;
}

/** Slug without the environment, e.g. `root-ca-01`. Used as the PKCS#11 token label. */
export function caKeyLabel(tier: CaTier, n: number): string {
  const label = `${tier}-ca-${pad(n)}`;
  if (label.length > MAX_PKCS11_LABEL_LENGTH) {
    throw new Error(`PKCS#11 label "${label}" is longer than ${MAX_PKCS11_LABEL_LENGTH} characters`);
  }
  return label;
}

/** Full slug with the environment, e.g. `tak-nz-try-root-ca-01`. Used for the KMS alias. */
export function caSlug(label: string, tier: CaTier, n: number): string {
  return `tak-nz-${environmentSlug(label)}-${caKeyLabel(tier, n)}`;
}
