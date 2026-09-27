// File-mutating tool calls (`edit`, `write`, `apply_patch`) shaped like upstream OpenClaw's:
// arguments as the agent sends them, and results with the `details` receipts the tools return
// (src/agents/sessions/tools/{edit,write,file-diff}.ts, src/agents/apply-patch.ts).

const CONTEXT = 4;

function splitLines(text) {
  const lines = text.split('\n');
  if (lines.at(-1) === '') lines.pop();
  return lines;
}

// Line diff (LCS) grouped into hunks with `CONTEXT` lines around each change, like jsdiff's structuredPatch.
function hunks(before, after) {
  const a = splitLines(before);
  const b = splitLines(after);
  const lcs = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      ops.push({ op: ' ', text: a[i++] });
      j++;
    } else if (i < a.length && (j === b.length || lcs[i + 1][j] >= lcs[i][j + 1])) ops.push({ op: '-', text: a[i++] });
    else ops.push({ op: '+', text: b[j++] });
  }
  const changed = ops.map((o, k) => (o.op === ' ' ? -1 : k)).filter((k) => k >= 0);
  const out = [];
  let k = 0;
  while (k < changed.length) {
    let start = Math.max(0, changed[k] - CONTEXT);
    let end = changed[k];
    while (k + 1 < changed.length && changed[k + 1] - end <= 2 * CONTEXT) end = changed[++k];
    k++;
    end = Math.min(ops.length - 1, end + CONTEXT);
    if (out.length && start <= out.at(-1).endOp) start = out.at(-1).endOp + 1;
    let oldStart = 1;
    let newStart = 1;
    for (let n = 0; n < start; n++) {
      if (ops[n].op !== '+') oldStart++;
      if (ops[n].op !== '-') newStart++;
    }
    const lines = ops.slice(start, end + 1).map((o) => `${o.op}${o.text}`);
    const oldLines = lines.filter((l) => l[0] !== '+').length;
    const newLines = lines.filter((l) => l[0] !== '-').length;
    out.push({
      oldStart: oldLines === 0 ? oldStart - 1 : oldStart,
      oldLines,
      newStart: newLines === 0 ? newStart - 1 : newStart,
      newLines,
      lines,
      endOp: end,
    });
  }
  return out;
}

// Mirrors upstream `prepareFileDiff`: `patch` is a headers-only unified diff, `diff` the numbered
// preview (`+12 text`, ` 11 text`, `   ...`).
export function fileDiff(path, before, after) {
  const list = hunks(before, after);
  const patch = [`--- ${path}`, `+++ ${path}`];
  for (const h of list) {
    patch.push(`@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@`, ...h.lines);
  }
  const newCount = after === '' ? 0 : splitLines(after).length;
  const width = String(Math.max(before.split('\n').length, after.split('\n').length)).length;
  const ellipsis = ` ${''.padStart(width, ' ')} ...`;
  const diff = [];
  let firstChangedLine;
  list.forEach((h, index) => {
    if (index > 0 || h.newStart > 1) diff.push(ellipsis);
    let oldNum = Math.max(h.oldStart, 1);
    let newNum = Math.max(h.newStart, 1);
    for (const line of h.lines) {
      const prefix = line[0];
      if (firstChangedLine === undefined && prefix !== ' ') firstChangedLine = newNum;
      diff.push(`${prefix}${String(prefix === '-' ? oldNum : newNum).padStart(width, ' ')} ${line.slice(1)}`);
      if (prefix !== '+') oldNum++;
      if (prefix !== '-') newNum++;
    }
    if (index === list.length - 1 && h.newStart + h.newLines <= newCount) diff.push(ellipsis);
  });
  return { diff: diff.join('\n'), patch: `${patch.join('\n')}\n`, firstChangedLine };
}

export const RETRY_PATH = 'src/net/retry.ts';
export const RETRY_TEST_PATH = 'src/net/retry.test.ts';

export const RETRY_BEFORE = `import { sleep } from './sleep';

export interface RetryOptions {
  attempts: number;
  baseDelayMs: number;
}

export async function withRetry<T>(fn: () => Promise<T>, opts: RetryOptions): Promise<T> {
  let attempt = 0;
  while (true) {
    try {
      return await fn();
    } catch (error) {
      attempt += 1;
      const delay = opts.baseDelayMs * 2 ** attempt;
      await sleep(delay);
    }
  }
}
`;

// Two replacements in one `edit` call → two hunks.
export const RETRY_EDITS = [
  {
    oldText: "import { sleep } from './sleep';\n",
    newText: "import { isRetryable } from './http-errors';\nimport { sleep } from './sleep';\n\nconst MAX_DELAY_MS = 30_000;\n",
  },
  {
    oldText: '      attempt += 1;\n      const delay = opts.baseDelayMs * 2 ** attempt;\n',
    newText: '      attempt += 1;\n      if (attempt >= opts.attempts || !isRetryable(error)) throw error;\n      const delay = Math.min(opts.baseDelayMs * 2 ** (attempt - 1), MAX_DELAY_MS);\n',
  },
];

export const RETRY_AFTER = RETRY_EDITS.reduce((text, e) => text.replace(e.oldText, e.newText), RETRY_BEFORE);

export const RETRY_TEST = `import { describe, expect, it, vi } from 'vitest';
import { HttpError } from './http-errors';
import { withRetry } from './retry';

describe('withRetry', () => {
  it('gives up after the configured attempts', async () => {
    const fn = vi.fn().mockRejectedValue(new HttpError(503));
    await expect(withRetry(fn, { attempts: 3, baseDelayMs: 1 })).rejects.toThrow('503');
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it('does not retry client errors', async () => {
    const fn = vi.fn().mockRejectedValue(new HttpError(404));
    await expect(withRetry(fn, { attempts: 3, baseDelayMs: 1 })).rejects.toThrow('404');
    expect(fn).toHaveBeenCalledTimes(1);
  });
});
`;

// Update (two hunks) + move with an update, add, delete: every apply_patch file operation.
export const CLIENT_PATCH = `*** Begin Patch
*** Update File: src/net/client.ts
@@ import { withRetry } from './retry';
-import { legacyRetry } from './legacy-retry';
+import type { RetryOptions } from './retry';
@@ export class ApiClient {
-  private retries = 3;
+  private readonly retry: RetryOptions = { attempts: 4, baseDelayMs: 250 };
@@ async request<T>(path: string): Promise<T> {
-    return legacyRetry(() => this.fetchJSON<T>(path), this.retries);
+    return withRetry(() => this.fetchJSON<T>(path), this.retry);
   }
*** Update File: src/net/errors.ts
*** Move to: src/net/http-errors.ts
@@ export class HttpError extends Error {
   constructor(readonly status: number) {
     super(\`HTTP \${status}\`);
   }
 }
+
+export function isRetryable(error: unknown): boolean {
+  return error instanceof HttpError && (error.status === 429 || error.status >= 500);
+}
*** Add File: docs/retry.md
+# Retries
+
+Requests retry up to 4 times on 429 and 5xx responses,
+backing off from 250 ms and capping at 30 s.
*** Delete File: src/net/legacy-retry.ts
*** End Patch`;

export const CLIENT_PATCH_SUMMARY = {
  added: ['docs/retry.md'],
  modified: ['src/net/client.ts', 'src/net/http-errors.ts'],
  deleted: ['src/net/legacy-retry.ts'],
};

export function patchSummaryText(summary) {
  return [
    'Success. Updated the following files:',
    ...summary.added.map((f) => `A ${f}`),
    ...summary.modified.map((f) => `M ${f}`),
    ...summary.deleted.map((f) => `D ${f}`),
  ].join('\n');
}

// The three calls of the seeded "Fix retry backoff" chat, with the results upstream records.
export function seededFileEditCalls() {
  const edit = fileDiff(RETRY_PATH, RETRY_BEFORE, RETRY_AFTER);
  const write = fileDiff(RETRY_TEST_PATH, '', RETRY_TEST);
  return [
    {
      id: 'call_seed_edit_retry',
      name: 'edit',
      args: { path: RETRY_PATH, edits: RETRY_EDITS },
      result: `Successfully replaced ${RETRY_EDITS.length} block(s) in ${RETRY_PATH}.`,
      details: { changed: true, ...edit },
    },
    {
      id: 'call_seed_write_test',
      name: 'write',
      args: { path: RETRY_TEST_PATH, content: RETRY_TEST },
      result: `Successfully wrote ${Buffer.byteLength(RETRY_TEST, 'utf8')} bytes to ${RETRY_TEST_PATH}`,
      details: { changed: true, created: true, ...write },
    },
    {
      id: 'call_seed_patch_client',
      name: 'apply_patch',
      args: { input: CLIENT_PATCH },
      result: patchSummaryText(CLIENT_PATCH_SUMMARY),
      details: { summary: CLIENT_PATCH_SUMMARY },
    },
  ];
}

const CONFIG_PATH = 'config/retry.json';
const CONFIG_BEFORE = '{\n  "attempts": 3,\n  "baseDelayMs": 100\n}\n';
const CONFIG_AFTER = '{\n  "attempts": 4,\n  "baseDelayMs": 250\n}\n';

// A live run's call (top-level `oldText`/`newText`, the single-edit form).
export function liveFileEditCall() {
  const oldText = '  "attempts": 3,\n  "baseDelayMs": 100\n';
  const newText = '  "attempts": 4,\n  "baseDelayMs": 250\n';
  return {
    name: 'edit',
    args: { path: CONFIG_PATH, oldText, newText },
    result: `Successfully replaced 1 block(s) in ${CONFIG_PATH}.`,
    details: { changed: true, ...fileDiff(CONFIG_PATH, CONFIG_BEFORE, CONFIG_AFTER) },
  };
}
