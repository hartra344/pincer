// Mock Gateway for the persistence bench (scripts/bench-persistence.sh): one chat with
// BENCH_ITEMS messages, and a log line for every chat.history read of it.
import { startServer } from '../mock-gateway/server.mjs';

const KEY = 'agent:main:dashboard:trip';
const total = Number(process.env.BENCH_ITEMS ?? 22000);
const port = Number(process.env.PORT ?? 18931);

const server = await startServer({ port, auth: 'none', pairing: 'off', stdin: false });
const transcript = server.state.transcripts.get(KEY);
const filler = 'The quick brown fox jumps over the lazy dog while the benchmark pads this message out to a realistic length. ';
const now = Date.now();
const seeded = Array.from({ length: total }, (_, i) => ({
  role: i % 2 === 0 ? 'user' : 'assistant',
  content: [{ type: 'text', text: `Message ${i}: ${filler.repeat(3)}` }],
  timestamp: now - (total - i) * 1000,
  __openclaw: { id: `bench-${i}` },
}));
transcript.unshift(...seeded);

const slice = transcript.slice.bind(transcript);
transcript.slice = (...args) => {
  console.log(`BENCH_HISTORY ${KEY} ${args[0]}-${args[1]}`);
  return slice(...args);
};
console.log(`BENCH_READY ${KEY} ${transcript.length}`);
