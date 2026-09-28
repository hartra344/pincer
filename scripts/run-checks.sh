#!/usr/bin/env bash
# Runs the unit tests and every PincerChecks mode side by side, each live mode against its own
# fresh mock gateway. CI runs it after `swift build --build-tests`; locally, build first too.
#
#   scripts/run-checks.sh [extra swift flags…]
#
# Env: CHECKS_LOG_DIR (default: a temp folder), CHECKS_PORT_BASE (default 18801; uses 4 ports).
set -uo pipefail
cd "$(dirname "$0")/.."

SWIFT_FLAGS=("$@")
LOGS="${CHECKS_LOG_DIR:-$(mktemp -d)}"
PORT_BASE="${CHECKS_PORT_BASE:-18801}"
mkdir -p "$LOGS"
export PINCER_KEYCHAIN=memory

BIN="$(swift build --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})" || exit 1
CHECKS="$BIN/PincerChecks"
[ -x "$CHECKS" ] || { echo "No $CHECKS: build first (swift build --build-tests)"; exit 1; }
[ -d mock-gateway/node_modules ] || { echo "Run npm ci in mock-gateway first"; exit 1; }

mocks=()
cleanup() { for pid in ${mocks[@]+"${mocks[@]}"}; do kill "$pid" 2>/dev/null; done; }
trap cleanup EXIT

# name, port, env… → a mock on that port, logging to $LOGS/mock-name.log
start_mock() {
    local name=$1 port=$2
    shift 2
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        echo "Port $port is already in use; set CHECKS_PORT_BASE to another range"
        exit 1
    fi
    env PORT="$port" "$@" node mock-gateway/server.mjs > "$LOGS/mock-$name.log" 2>&1 &
    mocks+=($!)
}

# Mocks start just before the checks: some of their seeded data expires minutes after launch.
start_mock core $((PORT_BASE))
start_mock extras $((PORT_BASE + 1))
start_mock no-usage $((PORT_BASE + 2)) MOCK_NO_USAGE=1
start_mock no-reply-to $((PORT_BASE + 3)) MOCK_NO_REPLY_TO=1
for port in $((PORT_BASE)) $((PORT_BASE + 1)) $((PORT_BASE + 2)) $((PORT_BASE + 3)); do
    for _ in $(seq 1 30); do nc -z 127.0.0.1 "$port" 2>/dev/null && break; sleep 1; done
    if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
        echo "Mock on port $port didn't start:"
        cat "$LOGS"/mock-*.log
        exit 1
    fi
done

names=()
pids=()
# name, command… → runs in the background, logging to $LOGS/name.log and its duration to name.seconds
lane() {
    local name=$1
    shift
    (
        start=$(date +%s)
        "$@"
        code=$?
        echo $(($(date +%s) - start)) > "$LOGS/$name.seconds"
        exit $code
    ) > "$LOGS/$name.log" 2>&1 &
    names+=("$name")
    pids+=($!)
}

url() { echo "ws://127.0.0.1:$(($PORT_BASE + $1))"; }
fast=(env PINCER_DEMO_DELAY_SCALE=0.2)
# Only the plain run does the slow Shortcuts & Siri offline checks; the others skip them.
# All of these share the CPU, so none enforces the perf smoke budgets (their timings are just
# reported); a separate run enforces them afterwards, alone.
lane unit-tests swift test --skip-build --parallel ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
lane self-checks "$CHECKS" --skip-perf-budgets
lane demo "${fast[@]}" "$CHECKS" --skip-intent-checks --skip-perf-budgets --demo
lane live-core "${fast[@]}" "$CHECKS" --skip-intent-checks --skip-perf-budgets --live-core "$(url 0)" dev-token
lane live-extras "${fast[@]}" "$CHECKS" --skip-intent-checks --skip-perf-budgets --live-extras "$(url 1)" dev-token
lane live-no-usage "$CHECKS" --skip-intent-checks --skip-perf-budgets --live-no-usage "$(url 2)" dev-token
lane live-no-reply-to "$CHECKS" --skip-intent-checks --skip-perf-budgets --live-no-reply-to "$(url 3)" dev-token

status=0
summary=()
# Waits for lanes from index $1 on, then prints their logs and adds them to the summary.
report() {
    local i name result seconds
    for ((i = $1; i < ${#pids[@]}; i++)); do
        name=${names[$i]}
        if wait "${pids[$i]}"; then result=passed; else result=FAILED; status=1; fi
        seconds=$(cat "$LOGS/$name.seconds" 2>/dev/null || echo "?")
        echo "::group::$name ($result)"
        cat "$LOGS/$name.log"
        echo "::endgroup::"
        summary+=("$(printf '%-18s %-7s %4ss  %s' "$name" "$result" "$seconds" "$(tail -n 1 "$LOGS/$name.log")")")
    done
}
report 0
# The perf smoke budgets are wall-clock, so they only mean something with the CPU to themselves.
# Likewise the unit tests' perf budgets: the parallel lane above only holds them to a generous
# ceiling (`PerfBudget` in Tests/PincerKitTests/Support.swift); this solo run enforces them.
lane perf-smoke "$CHECKS" --perf-smoke
report $((${#pids[@]} - 1))
lane perf-tests env PINCER_STRICT_PERF=1 swift test --skip-build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
    --filter 'manyRunsAndEventsStayFast|largeFlatInputBuildsQuickly'
report $((${#pids[@]} - 1))

echo
grep -H "✗\|timed out" "$LOGS"/*.log || true
echo
echo "Lane               Result  Time   Last line"
printf '%s\n' "${summary[@]}"
echo "Logs: $LOGS"
exit $status
