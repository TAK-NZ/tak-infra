/**
 * Resolve the `database.instanceClass` setting to a provisioned Aurora instance type.
 *
 * `db.serverless` is handled by the caller (it selects the Serverless v2 branch of the
 * Database construct); this is only for provisioned instances.
 *
 * Supported classes are matched exactly:
 *   - `db.t4g.medium`, `db.t4g.large`
 *   - `db.r6g.*`, `db.r7g.*`, `db.r8g.*` from `large` up to `16xlarge`
 *
 * Anything else keeps the behaviour this construct has always had: the T4G family, `large`
 * when the value contains "large" and `medium` otherwise (so a leftover `db.t4g.small` still
 * means `db.t4g.medium`, the smallest class Aurora PostgreSQL offers on T4G). The caller
 * reports that case with a synth-time warning, because the value is not being honoured.
 *
 * Kept free of CDK imports so it can be tested directly.
 */
export interface ProvisionedInstanceClass {
  /** Instance type without the `db.` prefix, for example `t4g.large` or `r6g.large`. */
  readonly instanceType: string;
  /** True when `instanceClass` matched a supported class; false when the legacy fallback applied. */
  readonly recognised: boolean;
}

const SUPPORTED_CLASS = /^db\.(t4g\.(medium|large)|(r6g|r7g|r8g)\.(large|xlarge|2xlarge|4xlarge|8xlarge|12xlarge|16xlarge))$/;

export function resolveProvisionedInstanceClass(instanceClass: string): ProvisionedInstanceClass {
  if (SUPPORTED_CLASS.test(instanceClass)) {
    return { instanceType: instanceClass.slice('db.'.length), recognised: true };
  }
  return {
    instanceType: instanceClass.includes('large') ? 't4g.large' : 't4g.medium',
    recognised: false
  };
}
