# Performance tests

End-to-end CPU/throughput measurements for the *Invisible Tax* KubeCon India deck.

Goal: prove on our own hardware that
1. an OTel Collector OTLP-in / OTLP-out **passthrough** pipeline saturates ~1 core at a
   surprisingly low log rate, and
2. the CPU is being burned on decode/alloc/walk/encode — visible in a flamegraph.

## Topology

```
telemetrygen        →   SUT collector       →   Sink collector
(load generator)        otlp recv               otlp recv
                        no processors           no processors
                        otlphttp exporter       nop exporter
                        pprof on :1777          (drops everything)
```

Two separate `otelcol-contrib` processes so the SUT's pprof profile contains
only SUT work. Both are native binaries (not Docker) so pprof symbols are
clean and there's no container CPU accounting noise.

## One-time setup

```bash
cd perftests
./scripts/setup.sh           # downloads otelcol-contrib + builds telemetrygen
```

## Run a single configuration

```bash
./scripts/run.sh passthrough 10000   # rate = 10k logs/s, duration default 60s
```

Outputs land in `results/<config>-<rate>-<timestamp>/`:

- `cpu.prof`        — 30s pprof CPU profile of the SUT
- `flamegraph.svg`  — Brendan-Gregg-style flame from cpu.prof
- `loadgen.log`     — telemetrygen output (lets you see if it kept up)
- `sut.log`         — SUT collector stdout
- `sink.log`        — sink collector stdout
- `summary.txt`     — wall-clock CPU%, dropped count, achieved rate

## Find the saturation point

```bash
./scripts/sweep.sh passthrough   # tries 1k, 5k, 10k, 25k, 50k, 100k, 200k
```

Prints a one-line summary per rate so you can see where the SUT runs out of
single-core headroom.

## Configs

- `configs/sut-passthrough.yaml` — receiver → exporter, nothing in between
- `configs/sut-1transform.yaml`  — adds one transform/rename rule (future)
- `configs/sink.yaml`            — receiver → nop exporter

## Caveats

- macOS doesn't have `taskset`. We use `GOMAXPROCS=1` on the SUT to force
  single-threaded scheduling, but the OS can still migrate the thread. For
  *relative* numbers this is fine; for absolute "core saturation at exactly
  N logs/s" claims we'd want a Linux box.
- Apple Silicon perf cores are fast — numbers won't match Intel Xeon
  (Phase 2's hardware). What we're proving is *shape*: passthrough is
  surprisingly expensive, and adding transforms stacks linearly.
- The Mar 1 profile in `../cpu.prof` used `exporters: [debug]` which skips
  the encode half. This setup uses `otlphttp` so both decode AND encode
  are visible in the flame.
