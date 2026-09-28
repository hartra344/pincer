import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { appendLogLine, readLogSlice } from '../logs.mjs';
import { connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { server, url, device, deviceToken, sessions, done, dropped, message, missing, invalid } = ctx;
  // logs.tail: byte-offset polling with the Gateway's cursor, reset and truncation rules.
  {
    const tailer = await connectClient(url, device, deviceToken, true);
    assert.ok(tailer.hello.features.methods.includes('logs.tail'));
    const first = await tailer.send('logs.tail', {});
    assert.match(first.file, /^\/tmp\/openclaw\/openclaw-\d{4}-\d{2}-\d{2}\.log$/);
    assert.ok(first.lines.length > 100 && first.lines.length <= 500, `seeded lines: ${first.lines.length}`);
    assert.equal(first.cursor, first.size);
    assert.equal(first.reset, false);
    assert.equal(first.skippedBytes, undefined);
    const parsed = first.lines.map((line) => { try { return JSON.parse(line); } catch { return null; } });
    const levels = new Set(parsed.filter(Boolean).map((obj) => obj._meta.logLevelName));
    for (const level of ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL']) assert.ok(levels.has(level), `seeded ${level}`);
    assert.ok(parsed.some((obj) => obj === null), 'seeded plain-text lines');
    const boot = parsed.find((obj) => obj?.['1'] === 'listening on ws://127.0.0.1:18789');
    assert.equal(boot?.['0'], undefined);
    assert.equal(parsed.find((obj) => obj?.['0'] === obj?._meta.name)?.['1'], 'control UI served at /');
    appendLogLine(server.state.logsState, 'info', 'gateway', 'selftest marker line');
    const next = await tailer.send('logs.tail', { cursor: first.cursor });
    assert.equal(next.file, first.file);
    assert.ok(next.lines.some((line) => line.includes('selftest marker line')));
    assert.ok(next.cursor > first.cursor);
    assert.equal(next.reset, false);
    const idle = await tailer.send('logs.tail', { cursor: server.state.logsState.size });
    assert.deepEqual(idle.lines, []);
    for (const params of [{ follow: true }, { limit: 0 }, { limit: 5001 }, { limit: 1.5 }, { maxBytes: 0 }, { maxBytes: 1_000_001 }, { cursor: -1 }, { cursor: '10' }]) {
      const bad = await tailer.call('logs.tail', params);
      assert.equal(bad.error.code, 'INVALID_REQUEST', JSON.stringify(params));
      assert.match(bad.error.message, /^invalid logs\.tail params/);
    }
    const limited = await tailer.send('logs.tail', { limit: 3 });
    assert.equal(limited.lines.length, 3);
    assert.equal(limited.truncated, true);
    const midLine = await tailer.send('logs.tail', { cursor: first.cursor - 5, limit: 5000 });
    assert.ok(midLine.lines.every((line) => !line.startsWith('"')), 'partial first line dropped');
    const small = await tailer.send('logs.tail', { maxBytes: 1000 });
    assert.equal(small.truncated, true);
    assert.ok(small.lines.reduce((n, line) => n + Buffer.byteLength(line, 'utf8') + 1, 0) <= 1000, 'maxBytes counts UTF-8 bytes');
    const RESULT_KEYS = new Set(['file', 'cursor', 'size', 'lines', 'truncated', 'reset', 'skippedBytes']);
    for (const res of [first, next, idle, limited, midLine, small]) {
      for (const key of Object.keys(res)) assert.ok(RESULT_KEYS.has(key), `unexpected result key ${key}`);
      for (const key of ['file', 'cursor', 'size', 'lines']) assert.ok(key in res, `missing result key ${key}`);
      assert.ok(Number.isInteger(res.cursor) && res.cursor >= 0 && res.cursor <= res.size);
    }
    const ahead = await tailer.send('logs.tail', { cursor: server.state.logsState.size + 1000 });
    assert.equal(ahead.reset, true);
    assert.equal(ahead.skippedBytes, undefined);
    for (const params of [null, [], 'x']) {
      const bad = await tailer.call('logs.tail', params);
      assert.equal(bad.error?.code, 'INVALID_REQUEST', `params ${JSON.stringify(params)}`);
    }
    // Byte offsets, not characters: a detached in-memory file with multi-byte lines.
    {
      const file = { file: '/tmp/openclaw/openclaw-2026-09-26.log', lines: [], starts: [], size: 0, counter: 0 };
      const wide = 'é🦞 → done';
      appendLogLine(file, 'info', 'gateway', 'first');
      const afterFirst = file.size;
      assert.equal(afterFirst, Buffer.byteLength(file.lines[0], 'utf8') + 1);
      file.lines.push(wide); file.starts.push(file.size); file.size += Buffer.byteLength(wide, 'utf8') + 1;
      assert.equal(file.size - afterFirst, 16);
      assert.notEqual(Buffer.byteLength(wide, 'utf8'), wide.length);
      const tail = readLogSlice(file, { cursor: afterFirst });
      assert.deepEqual(tail.lines, [wide]);
      assert.equal(tail.cursor, file.size);
      file.lines.push('after'); file.starts.push(file.size); file.size += 6;
      assert.deepEqual(readLogSlice(file, { cursor: afterFirst + 2 }).lines, ['after'], 'cursor mid multi-byte line skips the partial line');
      assert.deepEqual(readLogSlice(file, { cursor: file.size }).lines, []);
      const exact = readLogSlice(file, { cursor: file.size - 10, maxBytes: 10 });
      assert.equal(exact.reset, false);
      const behind = readLogSlice(file, { cursor: 0, maxBytes: 10 });
      assert.equal(behind.reset, true);
      assert.equal(behind.skippedBytes, file.size - 10);
      assert.deepEqual(behind.lines, ['after']);
      const limitedSlice = readLogSlice(file, { cursor: 0, limit: 1 });
      assert.deepEqual(limitedSlice.lines, ['after']);
      assert.equal(limitedSlice.truncated, true);
      assert.equal(limitedSlice.reset, false);
      const empty = readLogSlice({ ...file, lines: [], starts: [], size: 0 }, {});
      assert.deepEqual([empty.lines, empty.cursor, empty.size], [[], 0, 0]);
    }

    const sendTrigger = (text) => tailer.send('chat.send', { sessionKey: 'agent:main:main', message: text, idempotencyKey: `idem_${crypto.randomUUID()}` });
    await tailer.send('sessions.messages.subscribe', { key: 'agent:main:main' });
    const beforeRotate = await tailer.send('logs.tail', {});
    await sendTrigger('rotate please [mock:rotate-logs]');
    const rotated = await tailer.send('logs.tail', { cursor: beforeRotate.cursor });
    assert.notEqual(rotated.file, beforeRotate.file);
    assert.equal(rotated.reset, true);
    assert.ok(rotated.lines.some((line) => line.includes('log file opened')));
    await sendTrigger('truncate please [mock:truncate-logs]');
    const truncated = await tailer.send('logs.tail', { cursor: rotated.cursor });
    assert.equal(truncated.file, rotated.file);
    assert.equal(truncated.reset, true);
    assert.equal(truncated.skippedBytes, undefined);
    const beforeBurst = await tailer.send('logs.tail', {});
    await sendTrigger('burst please [mock:log-burst]');
    const burst = await tailer.send('logs.tail', { cursor: beforeBurst.cursor });
    assert.equal(burst.reset, true);
    assert.equal(burst.truncated, true);
    assert.ok(burst.skippedBytes > 0);
    assert.ok(burst.lines.length > 0 && burst.lines.length <= 500);
    await sendTrigger('fail please [mock:logs-unavailable]');
    for (let i = 0; i < 2; i += 1) {
      const failed = await tailer.call('logs.tail', { cursor: burst.cursor });
      assert.equal(failed.error.code, 'UNAVAILABLE');
      assert.match(failed.error.message, /^log read failed: EACCES/);
    }
    assert.equal((await tailer.call('logs.tail', { cursor: burst.cursor })).ok, true);
    tailer.ws.close();
    const noRead = await connectClient(url, device, 'dev-token', true, ['operator.approvals']);
    const noReadScope = await noRead.call('logs.tail', {});
    assert.equal(noReadScope.error.details.code, 'MISSING_SCOPE');
    assert.equal(noReadScope.error.details.scope, 'operator.read');
    noRead.ws.close();
    process.env.MOCK_NO_LOGS = '1';
    try {
      const noLogs = await connectClient(url, device, deviceToken, true);
      assert.ok(!noLogs.hello.features.methods.includes('logs.tail'));
      const unknown = await noLogs.call('logs.tail', {});
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      noLogs.ws.close();
    } finally {
      delete process.env.MOCK_NO_LOGS;
    }
  }

}
