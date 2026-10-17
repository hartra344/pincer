const ADMIN_SCOPE = 'operator.admin';
const READ_SCOPE = 'operator.read';
const WRITE_SCOPE = 'operator.write';
const PAIRING_SCOPE = 'operator.pairing';

/** Like the Gateway: operator.admin covers every operator scope, operator.write covers read. */
export function scopeApproved(scopes, scope) {
  return scopes.includes(scope) || scopes.includes(ADMIN_SCOPE) || (scope === READ_SCOPE && scopes.includes(WRITE_SCOPE));
}

export function hasScope(conn, scope) {
  return scopeApproved(conn.scopes ?? [], scope);
}

export function hasPairingScope(conn) {
  return hasScope(conn, PAIRING_SCOPE);
}
