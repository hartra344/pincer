import Foundation

/// The demo's "Fix retry backoff" chat: an agent fixing a bug with the file-mutating tools, shaped
/// like upstream OpenClaw's (`edit` with Claude-style `file_path`/`old_string`/`new_string`, a
/// new-file `write`, and a multi-file, multi-hunk `apply_patch`), as `mock-gateway/file-edits.mjs`.
extension DemoGateway {
    static let fileEditsKey = "agent:coder:dashboard:retry-fix"
    static let fileEditsPreview = "Retries now stop after 4 attempts and skip 4xx errors."

    static let fileEditsEditCall = "call_demo_edit_retry"
    static let fileEditsWriteCall = "call_demo_write_test"
    static let fileEditsPatchCall = "call_demo_patch_client"
    static let fileEditsDeleteCall = "call_demo_delete_retry_adapter"

    static let fileEditsRetryPath = "src/net/retry.ts"
    static let fileEditsDeletePath = "src/net/retry-legacy-adapter.ts"
    static let fileEditsOld = """
        } catch (error) {
          attempt += 1;
          const delay = opts.baseDelayMs * 2 ** attempt;
          await sleep(delay);
        }
    """
    static let fileEditsNew = """
        } catch (error) {
          attempt += 1;
          if (attempt >= opts.attempts || !isRetryable(error)) throw error;
          const delay = Math.min(opts.baseDelayMs * 2 ** (attempt - 1), MAX_DELAY_MS);
          await sleep(delay);
        }
    """

    static let fileEditsTestPath = "src/net/retry.test.ts"
    static let fileEditsTest = """
    import { describe, expect, it, vi } from 'vitest';
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

    """

    /// Two-hunk update, update + move, add and delete: every `apply_patch` file operation.
    static let fileEditsPatch = """
    *** Begin Patch
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
         super(`HTTP ${status}`);
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
    *** End Patch
    """

    static let fileEditsDeletePatch = """
    *** Begin Patch
    *** Delete File: src/net/retry-legacy-adapter.ts
    *** End Patch
    """

    static func seedFileEditsTranscript() -> [JSONValue] {
        let minute = 60.0, hour = 3600.0
        let start = 5 * hour
        func result(_ id: String, _ tool: String, _ text: String, ago: Double, details: JSONValue? = nil) -> JSONValue {
            var extra: Row = ["toolCallId": .string(id), "toolName": .string(tool), "isError": false]
            if let details { extra["details"] = details }
            return Self.message("toolResult", [Self.text(text)], ago: ago, extra: extra)
        }
        let bytes = Self.fileEditsTest.utf8.count
        return [
            Self.message("user", [Self.text("""
            The API client hammers the server on 429s and never gives up. Fix the retry loop and add a test.
            """)], ago: start + 4 * minute),
            Self.message("assistant", [
                Self.thinking("withRetry loops forever and never checks the status; cap attempts and only retry 429/5xx."),
                Self.toolCall(Self.fileEditsEditCall, "edit", [
                    "file_path": .string(Self.fileEditsRetryPath),
                    "old_string": .string(Self.fileEditsOld),
                    "new_string": .string(Self.fileEditsNew),
                ]),
            ], ago: start + 3 * minute),
            result(Self.fileEditsEditCall, "edit", "Successfully replaced 1 block(s) in \(Self.fileEditsRetryPath).",
                   ago: start + 3 * minute - 2),
            Self.message("assistant", [
                Self.toolCall(Self.fileEditsWriteCall, "write", [
                    "path": .string(Self.fileEditsTestPath), "content": .string(Self.fileEditsTest),
                ]),
            ], ago: start + 2 * minute),
            result(Self.fileEditsWriteCall, "write", "Successfully wrote \(bytes) bytes to \(Self.fileEditsTestPath)",
                   ago: start + 2 * minute - 1, details: ["changed": true, "created": true]),
            Self.message("assistant", [
                Self.text("Now switching the client over and removing the old helper."),
                Self.toolCall(Self.fileEditsPatchCall, "apply_patch", ["input": .string(Self.fileEditsPatch)]),
            ], ago: start + minute),
            result(Self.fileEditsPatchCall, "apply_patch", """
            Success. Updated the following files:
            A docs/retry.md
            M src/net/client.ts
            M src/net/http-errors.ts
            D src/net/legacy-retry.ts
            """, ago: start + minute - 2, details: [
                "summary": [
                    "added": ["docs/retry.md"],
                    "modified": ["src/net/client.ts", "src/net/http-errors.ts"],
                    "deleted": ["src/net/legacy-retry.ts"],
                ],
            ]),
            Self.message("assistant", [
                Self.text("The old compatibility adapter is no longer used."),
                Self.toolCall(Self.fileEditsDeleteCall, "apply_patch", ["input": .string(Self.fileEditsDeletePatch)]),
            ], ago: start + 30),
            result(Self.fileEditsDeleteCall, "apply_patch", """
            Success. Updated the following files:
            D \(Self.fileEditsDeletePath)
            """, ago: start + 28),
            Self.message("assistant", [Self.text("""
            \(Self.fileEditsPreview) `retry.test.ts` covers both cases, and the old retry helpers are gone.
            """)], ago: start),
        ]
    }
}
