import { Static, TSchema, TUnknown } from '@sinclair/typebox';
export type TypeOpts = {
    verbose?: boolean;
    default?: boolean;
    convert?: boolean;
    clean?: boolean;
};
export default class TypeValidator {
    /**
     * Arbitrary JSON objects occasionally need to get typed as part of an ETL
     * This function provides the ability to strictly type unknown objects at runtime
     */
    static type<T extends TSchema = TUnknown>(type: T, body: unknown, opts?: TypeOpts): Static<T>;
}
