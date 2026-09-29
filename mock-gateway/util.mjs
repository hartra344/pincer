import crypto from 'node:crypto';
import { handleWebPushEvent } from './webpush.mjs';

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value ?? null);
}

export function randHex(bytes = 16) {
  return crypto.randomBytes(bytes).toString('hex');
}

export function shortId(prefix = '') {
  return `${prefix}${crypto.randomBytes(6).toString('hex')}`;
}

export function nowMs() {
  return Date.now();
}

export function textBlock(text) {
  return { type: 'text', text };
}

export function thinkingBlock(thinking) {
  return { type: 'thinking', thinking };
}

export function toolCallBlock(id, name, args) {
  return { type: 'toolCall', id, name, arguments: args };
}

export function imageBlock(artifactId, alt = 'Mock chart') {
  return { type: 'image', artifactId, mimeType: 'image/png', alt, width: 320, height: 200 };
}

export const DEFAULT_MODEL = { provider: 'anthropic', model: 'claude-opus-4-8' };

export const DEFAULT_CONTEXT_TOKENS = 128_000;

export function makeMessage(role, content, extras = {}) {
  // Like the Gateway, assistant messages record the model that wrote them.
  const model = role === 'assistant' ? (extras.model ?? DEFAULT_MODEL) : undefined;
  return {
    role,
    content,
    timestamp: nowMs(),
    ...(model ? { provider: model.provider, model: model.model } : {}),
    __openclaw: { id: crypto.randomUUID(), ...extras.openclaw },
    ...extras.extra,
  };
}

export function clone(value) {
  return structuredClone(value);
}

export function sendJson(ws, obj) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

// MOCK_DELAY_METHODS / mock.control setDelay hold back a request's response (see control.mjs).
function deliverResponse(conn, id, frame) {
  const ms = conn.delayRes?.get(id);
  if (!ms) return sendJson(conn.ws, frame);
  conn.delayRes.delete(id);
  setTimeout(() => {
    if (conn.ws.readyState === 1) sendJson(conn.ws, frame);
  }, ms);
}

export function sendRes(conn, id, payload) {
  deliverResponse(conn, id, { type: 'res', id, ok: true, payload });
}

export function sendErr(conn, id, code, message, details = undefined) {
  deliverResponse(conn, id, { type: 'res', id, ok: false, error: { code, message, ...(details ? { details } : {}) } });
}

export function sendEvent(conn, event, payload) {
  conn.seq += 1;
  sendJson(conn.ws, { type: 'event', event, payload, seq: conn.seq });
}

export function broadcast(state, event, payload, predicate = () => true) {
  // Upstream stamps every agent event with its emit time.
  if (event === 'agent' && payload.ts === undefined) payload = { ...payload, ts: nowMs() };
  for (const conn of state.connections) {
    if (conn.authenticated && predicate(conn)) sendEvent(conn, event, payload);
  }
  handleWebPushEvent(state, event, payload);
}
