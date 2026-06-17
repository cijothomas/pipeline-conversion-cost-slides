#!/usr/bin/env bash
# Sweep: passthrough → +1 rename → +2 renames → +4 renames.
# Each config is run unbounded with batched logs; we record achieved
# throughput and CPU% breakdown by category.
#
# Usage:
#   ./scripts/transform_sweep.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGS=("passthrough" "rename1" "rename2" "rename4")
DURATION="${DURATION:-60}"
BATCH_SIZE="${BATCH_SIZE:-1000}"

TS="$(date +%Y%m%d-%H%M%S)"
SWEEP_DIR="results/sweep-${TS}"
mkdir -p "$SWEEP_DIR"

SUMMARY="$SWEEP_DIR/summary.tsv"
echo -e "config\tlogs_per_sec\tsut_cpu_pct\tunmarshal_pct\tmarshal_pct\tmallocgc_pct\tgc_pct\ttransport_pct" > "$SUMMARY"

for CFG in "${CONFIGS[@]}"; do
  echo
  echo "==================== config=$CFG ===================="
  BATCH_SIZE="$BATCH_SIZE" ./scripts/run.sh "$CFG" 0 "$DURATION"
  RUN_DIR=$(ls -td "results/${CFG}-0-"* | head -1)

  # Achieved rate
  TOTAL=$(grep "logs generated" "$RUN_DIR/loadgen.log" | grep -oE 'logs":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s}')
  RATE=$((TOTAL / DURATION))

  # Average CPU% (last 10 samples)
  CPU=$(awk 'NR>1 {s+=$2; n++} END {if(n) printf "%.1f", s/n; else print "0"}' "$RUN_DIR/sut_cpu_sample.txt")

  PROF="$RUN_DIR/cpu.prof"

  pct_of_total() {
    local pattern="$1"
    go tool pprof -top -cum -focus="$pattern" "$PROF" 2>/dev/null \
      | grep "Showing nodes accounting" \
      | head -1 \
      | sed -E 's/.* ([0-9.]+)% of .*/\1/'
  }

  UNMARSH=$(pct_of_total "Unmarshal")
  MARSH=$(pct_of_total "MarshalToSizedBuffer|MarshalTo|MarshalLogs|encoding/proto.*Marshal")
  MALLOC=$(pct_of_total "mallocgc|newobject")
  GC=$(pct_of_total "gcDrain|gcBgMark|scanobject|greyobject|writeBarrier|gcWriteBarrier")
  TRANSPORT=$(pct_of_total "syscall|kevent|netpoll")

  echo -e "${CFG}\t${RATE}\t${CPU}\t${UNMARSH}\t${MARSH}\t${MALLOC}\t${GC}\t${TRANSPORT}" | tee -a "$SUMMARY"

  # Copy run dir into sweep dir for archival
  cp -r "$RUN_DIR" "$SWEEP_DIR/${CFG}/"

  sleep 5
done

echo
echo "==================== summary ===================="
column -t -s $'\t' < "$SUMMARY"
echo
echo "Archived under: $SWEEP_DIR"
