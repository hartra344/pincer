#!/usr/bin/env node
// Metadata only: never publish raw log tails, test arguments, descriptions or source payloads.
import fs from 'node:fs';
import path from 'node:path';

const [directory, rawInterval, ...arguments_] = process.argv.slice(2);
const requested = Number(rawInterval);
const interval = Number.isFinite(requested) && requested >= 0.05 ? requested : 30;
const lanes = arguments_.slice(0, 12).flatMap(argument => {
  const match = /^([A-Za-z0-9_-]{1,40})=([0-9]{1,12})$/.exec(argument);
  return match ? [{ name: match[1], pid: match[2], offset: 0, carry: '', skipLine: false,
    started: 0, finished: 0, active: new Map(), skipped: false, lastEvent: null }] : [];
});
const readLimit = 64 * 1024;
const lineLimit = 512;
const identifierLimit = 128;

function sampleTests(lane, size) {
  if (size < lane.offset) {
    lane.offset = 0; lane.carry = ''; lane.active.clear(); lane.skipped = true; lane.lastEvent = null;
  }
  if (size - lane.offset > readLimit) {
    // Stay near the end without reading an accumulated full log on every snapshot.
    lane.offset = size - readLimit; lane.carry = ''; lane.skipLine = true;
    lane.active.clear(); lane.skipped = true; lane.lastEvent = null;
  }
  const length = Math.min(readLimit, size - lane.offset);
  if (length <= 0) return;
  let descriptor;
  try {
    descriptor = fs.openSync(path.join(directory, lane.name + '.log'), 'r');
    const buffer = Buffer.alloc(length);
    const count = fs.readSync(descriptor, buffer, 0, length, lane.offset);
    lane.offset += count;
    const lines = (lane.carry + buffer.subarray(0, count).toString('utf8')).split('\n');
    lane.carry = lines.pop() ?? '';
    for (const line of lines) {
      if (lane.skipLine) { lane.skipLine = false; continue; }
      if (line.length > lineLimit) continue;
      // Only a source-level function name survives; parameter values and descriptions do not.
      const match = /^(?:◇|✔|✘|✓) Test ([A-Za-z_][A-Za-z0-9_.]{0,100})\([^\r\n]*\) (started\.|passed(?: after.*)?|failed(?: after.*)?)$/.exec(line);
      if (!match) continue;
      const identifier = match[1] + '()';
      lane.lastEvent = { identifier, kind: match[2] === 'started.' ? 'started' : 'finished' };
      if (match[2] === 'started.') {
        lane.started++;
        const prior = lane.active.get(identifier) ?? 0;
        lane.active.delete(identifier);
        if (lane.active.size >= identifierLimit) {
          lane.active.delete(lane.active.keys().next().value); lane.skipped = true;
        }
        lane.active.set(identifier, prior + 1);
      } else {
        lane.finished++;
        const count = lane.active.get(identifier);
        if (count > 1) lane.active.set(identifier, count - 1);
        else lane.active.delete(identifier);
      }
    }
    if (lane.carry.length > lineLimit) { lane.carry = ''; lane.skipLine = true; }
  } catch { /* A missing/rotated log is diagnostic uncertainty, not a failed checks lane. */ }
  finally { if (descriptor !== undefined) fs.closeSync(descriptor); }
}

function snapshot() {
  const states = lanes.map(lane => ({ lane, done: fs.existsSync(path.join(directory, lane.name + '.seconds')) }));
  const pending = states.find(state => !state.done);
  if (!pending) return;
  const lane = pending.lane;
  let size = 0;
  try { size = fs.statSync(path.join(directory, lane.name + '.log')).size; } catch {}
  if (lane.name === 'unit-tests' || lane.name === 'perf-tests') sampleTests(lane, size);
  const unfinished = Array.from(lane.active.keys()).at(-1);
  const last = unfinished ?? lane.lastEvent?.identifier ?? '-';
  const kind = unfinished ? 'unfinished' : lane.lastEvent?.kind ?? 'unknown';
  const statesText = states.map(state => state.lane.name + ':' + (state.done ? 'C' : 'P')).join(',');
  const message = `[checks progress] pending ${lane.name} pid=${lane.pid} log=${lane.name}.log bytes=${size}`
    + ` last=${last} kind=${kind} observedStarted=${lane.started} observedFinished=${lane.finished} skipped=${lane.skipped ? 1 : 0}`
    + ` lanes=${statesText}`;
  process.stdout.write(message.slice(0, lineLimit - 1) + '\n');
}
const timer = setInterval(snapshot, Math.min(interval * 1000, 2_147_483_647));
process.on('SIGTERM', () => { clearInterval(timer); process.exit(0); });
process.on('SIGINT', () => { clearInterval(timer); process.exit(0); });
process.stdout.on('error', () => { clearInterval(timer); process.exit(0); });
snapshot();
