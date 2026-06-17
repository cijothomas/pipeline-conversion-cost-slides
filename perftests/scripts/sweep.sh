#!/usr/bin/env bash
# Sweep over rates to find where the SUT saturates 1 core.
#
#   ./scripts/sweep.sh passthrough

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-passthrough}"
RATES="${RATES:-1000 5000 10000 25000 50000 100000 200000}"

echo "Sweep: config=$CONFIG  rates=$RATES"
echo

for R in $RATES; do
  echo "==================== rate=$R ===================="
  ./scripts/run.sh "$CONFIG" "$R" 45 || { echo "(failed at $R, stopping)"; break; }
  sleep 5   # let things settle between runs
done

echo
echo "Sweep done. Compare results/${CONFIG}-*/summary.txt"
