# Rename benchmark results

Run: `cargo bench --bench rename`
Hardware: Apple Silicon M-series (MacBook Pro), release build (LTO + 1 codegen unit)
Date: 2026-06-17
Criterion version: 0.5

Each case renames `exception.type` → `exception.kind`.

| # | Bench | Mean (ns) | Notes |
|---|---|---:|---|
| 1 | `1_string_swap` | **1.0** | `&'static str` reassignment — true pointer swap |
| 2 | `2_top_level_field` | **2.1** | `&'static str` field on a struct |
| 3 | `3_vec_attrs_8` | **18.6** | `Vec<(String, String)>` of 8 attrs, linear scan + swap |
| 4 | `4_hashmap_attrs_8` | **62** | `HashMap<String, String>` of 8 attrs, remove + insert |
| 5 | `5_batch_500_records` | **41,800** (≈ 84 ns/record) | case 4 across 500 records |

## What this proves for the talk

- **Pure string ops are ~1 ns** — the criterion harness floor; the actual swap is below the measurement noise.
- **Real-world rename cost lives in the data structure**, not the string. Vec scan ≈ 18 ns; HashMap ≈ 62 ns. Both still trivial.
- **A batch of 500 records costs ~42 µs total**, ≈ 84 ns/record.

Compared to what a real Collector OTLP pipeline pays for the *same workload* — Phase 2 reports ~81% CPU at 200K logs/s, ≈ 4 µs/record — the **rename itself is roughly 50× cheaper than the surrounding pipeline cost**. The "tax" is everything around the rename: decode, allocate, walk, re-encode, GC.

## Caveats

- These benchmarks are intentionally minimal — they don't model OTel's real `AttributeMap` (which is more complex) or the cost of going through processor framework layers in a real pipeline.
- Apple Silicon performance ≠ Intel Xeon (the Phase 2 hardware). Absolute numbers will differ by hardware; the *shape* of the escalation (string < struct < vec < map < batch) is what matters.
- HashMap variant uses two operations (`remove` then `insert`). A real implementation may rename in-place via the entry API; that would be marginally cheaper but doesn't change the order of magnitude.
