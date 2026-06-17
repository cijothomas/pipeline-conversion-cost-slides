#!/usr/bin/env bash
# Sweep: passthrough → +1 rename → +2 renames → +4 renames, using DEBUG exporter.
# Same as transform_sweep.sh but the SUT terminates at the debug exporter
# (basic verbosity, just counts). This removes the Marshal + second-hop
# transport cost from the picture, making decode/alloc/GC more visible.
#
# Note: no sink collector needed for debug mode.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGS=("passthrough-debug" "rename1-debug" "rename2-debug" "rename4-debug")
DURATION="${DURATION:-60}"
BATCH_SIZE="${BATCH_SIZE:-1000}"
PROF_SECS="${PROF_SECS:-30}"

BIN="$(pwd)/bin"
[[ -x "$BIN/otelcol-contrib" ]] || { echo "Run ./scripts/setup.sh first"; exit 1; }
[[ -x "$BIN/telemetrygen"    ]] || { echo "Run ./scripts/setup.sh first"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
SWEEP_DIR="results/sweep-debug-${TS}"
mkdir -p "$SWEEP_DIR"

SUMMARY="$SWEEP_DIR/summary.tsv"
echo -e "config\tlogs_per_sec\tsut_cpu_pct\tunmarshal_pct\tmallocgc_pct\tgc_pct\ttransport_pct" > "$SUMMARY"

BODY="login attempt: user=u-12345 ip=10.0.13.42 path=/api/v1/orders method=POST status=200 latency_ms=123 region=ap-south-1 trace_id=abcdef0123456789 span_id=fedcba9876543210"

cleanup() {
  [[ -n "${SUT_PID:-}" ]] && kill "$SUT_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for CFG in "${CONFIGS[@]}"; do
  echo
  echo "==================== config=$CFG ===================="

  RUN_DIR="results/${CFG}-${TS}"
  mkdir -p "$RUN_DIR"

  SUT_CFG="configs/sut-${CFG}.yaml"
  [[ -f "$SUT_CFG" ]] || { echo "missing $SUT_CFG"; continue; }

  echo "=> starting SUT (GOMAXPROCS=1)"
  GOMAXPROCS=1 "$BIN/otelcol-contrib" --config "$SUT_CFG" \
    > "$RUN_DIR/sut.log" 2>&1 &
  SUT_PID=$!
  sleep 3

  echo "=> sending load: rate=unbounded, duration=${DURATION}s, batch=${BATCH_SIZE}"
  (
    "$BIN/telemetrygen" logs \
      --otlp-endpoint localhost:4317 \
      --otlp-insecure \
      --rate 0 \
      --duration "${DURATION}s" \
      --workers 2 \
      --batch-size "$BATCH_SIZE" \
      --body "$BODY" \
      --otlp-attributes 'service.name="checkout"' \
      --otlp-attributes 'service.version="1.4.2"' \
      --otlp-attributes 'deployment.environment="prod"' \
      --telemetry-attributes 'http.method="POST"' \
      --telemetry-attributes 'http.status_code="200"' \
      --telemetry-attributes 'http.route="/api/v1/orders"' \
      --telemetry-attributes 'user.id="u-12345"' \
      --telemetry-attributes 'exception.type="java.io.IOException"' \
      > "$RUN_DIR/loadgen.log" 2>&1
  ) &
  LOADGEN_PID=$!

  sleep 5
  echo "=> capturing ${PROF_SECS}s CPU profile"
  curl -sS -o "$RUN_DIR/cpu.prof" \
    "http://localhost:1777/debug/pprof/profile?seconds=${PROF_SECS}"

  echo "=> sampling SUT CPU%"
  {
    echo "ts cpu_pct rss_kb"
    for _ in $(seq 1 10); do
      ps -o %cpu=,rss= -p "$SUT_PID" | awk -v ts="$(date +%s)" '{print ts, $1, $2}'
      sleep 1
    done
  } > "$RUN_DIR/sut_cpu_sample.txt"

  wait "$LOADGEN_PID" || true
  kill "$SUT_PID" 2>/dev/null || true
  wait "$SUT_PID" 2>/dev/null || true

  TOTAL=$(grep "logs generated" "$RUN_DIR/loadgen.log" | grep -oE 'logs":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s}')
  RATE=$((TOTAL / DURATION))
  CPU=$(awk 'NR>1 {s+=$2; n++} END {if(n) printf "%.1f", s/n; else print "0"}' "$RUN_DIR/sut_cpu_sample.txt")

  PROF="$RUN_DIR/cpu.prof"
  pct_of_total() {
    go tool pprof -top -cum -focus="$1" "$PROF" 2>/dev/null \
      | grep "Showing nodes accounting" \
      | head -1 \
      | sed -E 's/.* ([0-9.]+)% of .*/\1/'
  }

  UNMARSH=$(pct_of_total "Unmarshal")
  MALLOC=$(pct_of_total "mallocgc|newobject")
  GC=$(pct_of_total "gcDrain|gcBgMark|scanobject|greyobject|writeBarrier|gcWriteBarrier")
  TRANSPORT=$(pct_of_total "syscall|kevent|netpoll")

  go tool pprof -svg -output "$RUN_DIR/flamegraph.svg" "$PROF" \
    > "$RUN_DIR/pprof.log" 2>&1 || true

  echo -e "${CFG}\t${RATE}\t${CPU}\t${UNMARSH}\t${MALLOC}\t${GC}\t${TRANSPORT}" | tee -a "$SUMMARY"
  cp -r "$RUN_DIR" "$SWEEP_DIR/${CFG}/"

  sleep 5
done

echo
echo "==================== summary ===================="
column -t -s $'\t' < "$SUMMARY"
echo
echo "Archived under: $SWEEP_DIR"
