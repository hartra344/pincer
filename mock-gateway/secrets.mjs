// Gateway secrets store: secrets.store.set / list / delete (Gateway >= 2026.8). Shapes and errors follow the
// Gateway's server-methods/secrets.ts: names are env-style ids, `kind` is "secret" (value never disclosed) or
// "env" (value listed), and every method needs operator.admin. A `{source:"store", id}` SecretRef in the config
// resolves to the stored value (see resolveSecretRef). MOCK_NO_SECRETS=1 makes the mock look like an older Gateway.

export const SECRETS_METHODS = ['secrets.store.set', 'secrets.store.list', 'secrets.store.delete'];
export const SECRET_NAME_RE = /^[A-Z][A-Z0-9_]{0,127}$/;
const ADMIN_SCOPE = 'operator.admin';
const REDACTED = '__OPENCLAW_REDACTED__';

export function secretsDisabled() {
  return process.env.MOCK_NO_SECRETS === '1';
}

function store(state) {
  state.secretsStore ??= new Map();
  return state.secretsStore;
}

// The value a SecretRef or literal resolves to, or undefined when it does not resolve.
export function resolveSecretRef(state, value) {
  if (typeof value === 'string') return value && value !== REDACTED ? value : undefined;
  if (!value || typeof value !== 'object' || typeof value.id !== 'string') return undefined;
  if (value.source === 'store') return store(state).get(value.id)?.value;
  if (value.source === 'env') return state.configState?.config?.env?.vars?.[value.id];
  return undefined;
}

export function handleSecretsRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method } = msg;
  if (!SECRETS_METHODS.includes(method) || secretsDisabled()) return false;
  if (!(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const params = msg.params && typeof msg.params === 'object' && !Array.isArray(msg.params) ? msg.params : {};
  const entries = store(state);
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);

  switch (method) {
    case 'secrets.store.list':
      sendRes(conn, id, {
        entries: [...entries.entries()]
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([name, e]) => ({
            name,
            scopeKind: 'team',
            scopeId: '',
            kind: e.kind,
            createdAtMs: e.createdAtMs,
            updatedAtMs: e.updatedAtMs,
            updatedBy: 'Mock',
            ...(e.kind === 'env' ? { value: e.value } : { allowedHosts: e.allowedHosts }),
          })),
      });
      return true;
    case 'secrets.store.set': {
      const { name, value, kind = 'secret' } = params;
      if (typeof name !== 'string' || typeof value !== 'string') {
        invalid('invalid secrets.store.set params: name and value are required strings');
        return true;
      }
      if (kind !== 'secret' && kind !== 'env') {
        invalid('invalid secrets.store.set params: kind must be "secret" or "env"');
        return true;
      }
      if (!SECRET_NAME_RE.test(name)) {
        invalid(`Secret store name must match ${SECRET_NAME_RE}.`);
        return true;
      }
      if (value === REDACTED) {
        invalid(`Secret store entry "${name}" contains a redaction placeholder. Supply a real value or leave the field unchanged.`);
        return true;
      }
      if (kind === 'secret' && value.length === 0) {
        invalid('Secret store value is empty. Secret entries require a value; check the command that produced it.');
        return true;
      }
      const now = Date.now();
      const allowedHosts = [...new Set((Array.isArray(params.allowedHosts) ? params.allowedHosts : []).map(String))].sort();
      entries.set(name, { kind, value, allowedHosts, createdAtMs: entries.get(name)?.createdAtMs ?? now, updatedAtMs: now });
      sendRes(conn, id, { ok: true, reloaded: true });
      return true;
    }
    case 'secrets.store.delete': {
      if (typeof params.name !== 'string' || !params.name) {
        invalid('invalid secrets.store.delete params: name is required');
        return true;
      }
      entries.delete(params.name);
      sendRes(conn, id, { ok: true, reloaded: true });
      return true;
    }
  }
  return false;
}
