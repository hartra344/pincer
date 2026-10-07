#!/usr/bin/env bash
# Runs the unit tests and every PincerChecks mode side by side, each live mode against its own
# fresh mock gateway. CI runs it after `swift build --build-tests`; locally, build first too.
#
#   scripts/run-checks.sh [extra swift flags…]
#
# Env: CHECKS_LOG_DIR (default: a temp folder), CHECKS_PORT_BASE (default 18801; uses 6 ports).
# CHECKS_PROGRESS_INTERVAL defaults to 30s; fractional intervals are for the owned harness only.
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
mock_names=()
mock_ports=()
progress_pid=""
stop_progress() {
    if [ -n "$progress_pid" ]; then
        kill "$progress_pid" 2>/dev/null || true
        wait "$progress_pid" 2>/dev/null || true
        progress_pid=""
    fi
}
cleanup() {
    stop_progress
    for pid in ${mocks[@]+"${mocks[@]}"}; do kill "$pid" 2>/dev/null; done
}
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
    mock_names+=("$name")
    mock_ports+=("$port")
}

# Waits up to 30s for every mock to listen, polling every 0.05s. Fails with the mock's log as soon
# as one exits or times out.
wait_for_mocks() {
    local i name port deadline=$((SECONDS + 30))
    for i in "${!mocks[@]}"; do
        name=${mock_names[$i]} port=${mock_ports[$i]}
        until nc -z 127.0.0.1 "$port" 2>/dev/null; do
            if ! kill -0 "${mocks[$i]}" 2>/dev/null; then
                echo "Mock $name (port $port) exited before listening:"
                cat "$LOGS/mock-$name.log"
                exit 1
            fi
            if [ "$SECONDS" -ge "$deadline" ]; then
                echo "Mock $name (port $port) didn't start within 30s:"
                cat "$LOGS/mock-$name.log"
                exit 1
            fi
            sleep 0.05
        done
    done
}

# Mocks start just before the checks: some of their seeded data expires minutes after launch.
start_mock core $((PORT_BASE))
start_mock extras $((PORT_BASE + 1)) MOCK_LONG_CHAT=400
start_mock no-usage $((PORT_BASE + 2)) MOCK_NO_USAGE=1
start_mock no-reply-to $((PORT_BASE + 3)) MOCK_NO_REPLY_TO=1
start_mock reconnect $((PORT_BASE + 4))
start_mock no-session-reactions $((PORT_BASE + 5)) MOCK_NO_REACTIONS=1
wait_for_mocks

names=()
pids=()
# name, command… → runs in the background, logging to $LOGS/name.log and its duration to name.seconds
lane() {
    local name=$1
    shift
    # A reused log directory must not identify an older invocation as this lane's completion.
    rm -f "$LOGS/$name.seconds"
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
# Only the plain run does the offline suite (including Shortcuts & Siri); mode runs use their own suites.
# All of these share the CPU, so none enforces the perf smoke budgets (their timings are just
# reported); a separate run enforces them afterwards, alone.
lane unit-tests swift test --skip-build --parallel ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
lane self-checks "$CHECKS" --skip-perf-budgets
lane demo-core "${fast[@]}" "$CHECKS" --skip-perf-budgets --demo-core
lane demo-extras "${fast[@]}" "$CHECKS" --skip-perf-budgets --demo-extras
lane live-core "${fast[@]}" "$CHECKS" --skip-perf-budgets --live-core "$(url 0)" dev-token
lane live-extras "${fast[@]}" "$CHECKS" --skip-perf-budgets --live-extras "$(url 1)" dev-token
lane live-no-usage "$CHECKS" --skip-perf-budgets --live-no-usage "$(url 2)" dev-token
lane live-no-reply-to "$CHECKS" --skip-perf-budgets --live-no-reply-to "$(url 3)" dev-token
lane live-reconnect "$CHECKS" --skip-perf-budgets --live-reconnect "$(url 4)" dev-token
lane live-no-session-reactions "$CHECKS" --skip-perf-budgets --live-no-session-reactions "$(url 5)" dev-token

status=0
summary=()
# Waits for lanes from index $1 on, then prints their logs and adds them to the summary.
report() {
    local i name result seconds
    local progress_lanes=()
    for ((i = $1; i < ${#pids[@]}; i++)); do
        progress_lanes+=("${names[$i]}=${pids[$i]}")
    done
    # The solo performance lanes must keep the CPU to themselves.
    if [ "$1" -eq 0 ]; then
        node scripts/checks-pending-progress.mjs "$LOGS" "${CHECKS_PROGRESS_INTERVAL:-30}" "${progress_lanes[@]}" &
        progress_pid=$!
    fi
    for ((i = $1; i < ${#pids[@]}; i++)); do
        name=${names[$i]}
        if wait "${pids[$i]}"; then result=passed; else result=FAILED; status=1; fi
        seconds=$(cat "$LOGS/$name.seconds" 2>/dev/null || echo "?")
        echo "::group::$name ($result)"
        cat "$LOGS/$name.log"
        echo "::endgroup::"
        summary+=("$(printf '%-18s %-7s %4ss  %s' "$name" "$result" "$seconds" "$(tail -n 1 "$LOGS/$name.log")")")
    done
    stop_progress
}
report 0
# The perf smoke budgets are wall-clock, so they only mean something with the CPU to themselves.
# Likewise the unit tests' perf budgets: the parallel lane above only holds them to a generous
# ceiling (`PerfBudget` in Tests/PincerKitTests/Support.swift); this solo run enforces them.
# On CI (CI=true) the wall-clock *ratios* are only reported, even here, since shared runners are too
# noisy for them; the counter checks and absolute ceilings still apply. PINCER_WALL_CLOCK_CHECKS=1 opts in.
lane perf-smoke "$CHECKS" --perf-smoke
report $((${#pids[@]} - 1))
lane perf-tests env PINCER_STRICT_PERF=1 swift test --skip-build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
    --filter 'manyRunsAndEventsStayFast|largeFlatInputBuildsQuickly|StreamingProbe'
report $((${#pids[@]} - 1))

echo
grep -H "✗\|timed out" "$LOGS"/*.log || true
echo
echo "Lane               Result  Time   Last line"
printf '%s\n' "${summary[@]}"
echo "Logs: $LOGS"
exit $status
