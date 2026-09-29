#!/usr/bin/env bash
# Measures the transcript cache and message index (#199): bytes written per save, index CPU per
# save, saves per minute while streaming, and chat.history reads on a second launch.
# Usage: scripts/bench-persistence.sh [output-file]   (run from the package root; needs `npm install`
# in mock-gateway). Set BENCH_PORT (default 18931) and BENCH_STREAM_SECONDS (default 60).
set -euo pipefail
cd "$(dirname "$0")/.."

port=${BENCH_PORT:-18931}
work=${BENCH_DIR:-$PWD/.build/persistence-bench}
out=${1:-$work/results.txt}
rm -rf "$work" && mkdir -p "$work"
log="$work/mock.log"

export PINCER_BENCH=1 PINCER_BENCH_URL="ws://127.0.0.1:$port" PINCER_BENCH_MOCK_LOG="$log"
export PINCER_BENCH_GATEWAY_ID=$(uuidgen) PINCER_BENCH_STREAM_SECONDS=${BENCH_STREAM_SECONDS:-60}
export PINCER_CACHE_DIR="$work/cache"

run() { PINCER_BENCH_PHASE=$1 swift test --filter PersistenceBenchTests 2>&1 | grep -E '^BENCH |error:|✘|failed' || true; }

{
  echo "commit: $(git rev-parse --short HEAD)"
  PINCER_CACHE_DIR="$work/disk" run disk

  PORT=$port node scripts/bench-mock.mjs >"$log" 2>&1 &
  mock=$!
  for _ in $(seq 60); do grep -q BENCH_READY "$log" && break; sleep 0.5; done

  echo "--- launch 1 (empty cache)"; run launch
  echo "--- launch 2 (same cache)"; run launch
  echo "--- streaming"; run stream
  kill $mock 2>/dev/null || true
} | tee "$out"
