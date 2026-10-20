import { isObject } from './util.mjs';

const SHA256_RE = /^[a-fA-F0-9]{64}$/;

/** Field-type checks shared by the typebox-style params schemas; each returns a problem string or undefined. */
export const commonFieldTypes = {
  nonEmpty: (v) => (typeof v !== 'string' ? 'must be string' : v.length ? undefined : 'must NOT have fewer than 1 characters'),
  string: (v) => (typeof v === 'string' ? undefined : 'must be string'),
  boolean: (v) => (typeof v === 'boolean' ? undefined : 'must be boolean'),
  sha256: (v) => (typeof v === 'string' && SHA256_RE.test(v) ? undefined : 'must match pattern "^[a-fA-F0-9]{64}$"'),
};

/**
 * Checks `params` against `{required?, fields}` (field name -> key into `fieldTypes`): required properties
 * first, then unexpected properties and field types in key order. Returns a problem string or undefined.
 */
export function closedObjectProblem(schema, params, fieldTypes) {
  for (const key of schema.required ?? []) if (!(key in params)) return `at root: must have required property '${key}'`;
  for (const [key, value] of Object.entries(params)) {
    const type = schema.fields[key];
    if (!type) return `at root: unexpected property '${key}'`;
    const problem = fieldTypes[type](value);
    if (problem) return `at /${key}: ${problem}`;
  }
  return undefined;
}

/** Closed object of `allowed` keys, answering in the "must NOT have additional properties" shape; null when fine. */
export function additionalPropertiesProblem(method, params, allowed) {
  if (!isObject(params)) return `invalid ${method} params: must be object`;
  const extra = Object.keys(params).find((key) => !allowed.includes(key));
  return extra ? `invalid ${method} params: must NOT have additional properties (${extra})` : null;
}
