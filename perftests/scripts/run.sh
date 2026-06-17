#!/usr/bin/env bash
# Run a single passthrough experiment at a target rate.
#
#   ./scripts/run.sh passthrough 10000          # 10k logs/s, 60s default
#   ./scripts/run.sh passthrough 10000 90       # custom duration
#
# Outputs land in results/<config>-<rate>-<timestamp>/

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:?usage: run.sh <config> <rate> [duration_s]}"
RATE="${2:?rate required}"
DURATION="${3:-60}"
PROF_SECS="${PROF_SECS:-30}"   # how long to sample CPU; should be < DURATION

SUT_CFG="configs/sut-${CONFIG}.yaml"
SINK_CFG="configs/sink.yaml"
[[ -f "$SUT_CFG"  ]] || { echo "missing $SUT_CFG"; exit 1; }
[[ -f "$SINK_CFG" ]] || { echo "missing $SINK_CFG"; exit 1; }

BIN="$(pwd)/bin"
[[ -x "$BIN/otelcol-contrib" ]] || { echo "Run ./scripts/setup.sh first"; exit 1; }
[[ -x "$BIN/telemetrygen"    ]] || { echo "Run ./scripts/setup.sh first"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
OUT="results/${CONFIG}-${RATE}-${TS}"
mkdir -p "$OUT"

cleanup() {
  echo "=> cleanup"
  [[ -n "${SUT_PID:-}" ]]  && kill "$SUT_PID"  2>/dev/null || true
  [[ -n "${SINK_PID:-}" ]] && kill "$SINK_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=> starting sink (pid will be logged)"
"$BIN/otelcol-contrib" --config "$SINK_CFG" \
  > "$OUT/sink.log" 2>&1 &
SINK_PID=$!
echo "   sink pid=$SINK_PID"

echo "=> starting SUT (GOMAXPROCS=1)"
GOMAXPROCS=1 "$BIN/otelcol-contrib" --config "$SUT_CFG" \
  > "$OUT/sut.log" 2>&1 &
SUT_PID=$!
echo "   SUT  pid=$SUT_PID"

# Wait for both to be ready
sleep 3
if ! curl -sf "http://localhost:13133" >/dev/null && \
   ! curl -sf "http://localhost:13134" >/dev/null; then
  echo "WARNING: health check endpoints didn't respond — continuing anyway"
fi

echo "=> sending load: rate=${RATE} logs/s/worker (0=unbounded), duration=${DURATION}s, batch=${BATCH_SIZE:-1000}"
# Body padded to ~300 bytes (matches Phase 2 payload size).
BODY="login attempt: user=u-12345 ip=10.0.13.42 path=/api/v1/orders method=POST status=200 latency_ms=123 region=ap-south-1 trace_id=abcdef0123456789 span_id=fedcba9876543210"
(
  "$BIN/telemetrygen" logs \
    --otlp-endpoint localhost:4317 \
    --otlp-insecure \
    --rate "$RATE" \
    --duration "${DURATION}s" \
    --workers 2 \
    --batch-size "${BATCH_SIZE:-1000}" \
    --body "$BODY" \
    --otlp-attributes 'service.name="checkout"' \
    --otlp-attributes 'service.version="1.4.2"' \
    --otlp-attributes 'deployment.environment="prod"' \
    --telemetry-attributes 'http.method="POST"' \
    --telemetry-attributes 'http.status_code="200"' \
    --telemetry-attributes 'http.route="/api/v1/orders"' \
    --telemetry-attributes 'user.id="u-12345"' \
    --telemetry-attributes 'exception.type="java.io.IOException"' \
    > "$OUT/loadgen.log" 2>&1
) &
LOADGEN_PID=$!

# Give load a moment to ramp up, then capture pprof
sleep 5
echo "=> capturing ${PROF_SECS}s CPU profile"
curl -sS -o "$OUT/cpu.prof" \
  "http://localhost:1777/debug/pprof/profile?seconds=${PROF_SECS}"
echo "   saved $OUT/cpu.prof ($(du -h "$OUT/cpu.prof" | cut -f1))"

# Sample SUT CPU% during the rest of the load
echo "=> sampling ps for SUT CPU%"
{
  echo "ts cpu_pct rss_kb"
  for _ in $(seq 1 10); do
    ps -o %cpu=,rss= -p "$SUT_PID" | awk -v ts="$(date +%s)" '{print ts, $1, $2}'
    sleep 1
  done
} > "$OUT/sut_cpu_sample.txt"

# Wait for loadgen to finish
wait "$LOADGEN_PID" || true

# Render flamegraph (requires go installed)
if command -v go >/dev/null 2>&1; then
  echo "=> rendering flamegraph"
  go tool pprof -svg -output "$OUT/flamegraph.svg" "$OUT/cpu.prof" \
    > "$OUT/pprof.log" 2>&1 || echo "(pprof svg rendering had issues — see $OUT/pprof.log)"
else
  echo "(skipping flamegraph — go not installed)"
fi

# Summary
{
  echo "config:    $CONFIG"
  echo "rate:      $RATE logs/s"
  echo "duration:  ${DURATION}s"
  echo "prof_secs: ${PROF_SECS}s"
  echo "output:    $OUT"
  echo
  echo "--- loadgen tail ---"
  tail -20 "$OUT/loadgen.log"
  echo
  echo "--- SUT CPU% samples (avg of last 10s) ---"
  awk 'NR>1 {s+=$2; n++} END {if(n) printf "avg=%.1f%%\n", s/n}' "$OUT/sut_cpu_sample.txt"
} | tee "$OUT/summary.txt"
