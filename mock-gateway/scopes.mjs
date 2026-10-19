const ADMIN_SCOPE = 'operator.admin';
const READ_SCOPE = 'operator.read';
const WRITE_SCOPE = 'operator.write';
const PAIRING_SCOPE = 'operator.pairing';

/** Like the Gateway: operator.admin covers every operator scope, operator.write covers read. `scopes` is an array or a Set. */
export function scopeApproved(scopes, scope) {
  const has = scopes instanceof Set ? (s) => scopes.has(s) : (s) => scopes.includes(s);
  return has(scope) || has(ADMIN_SCOPE) || (scope === READ_SCOPE && has(WRITE_SCOPE));
}

export function hasScope(conn, scope) {
  return scopeApproved(conn.scopes ?? [], scope);
}

export function hasPairingScope(conn) {
  return hasScope(conn, PAIRING_SCOPE);
}
