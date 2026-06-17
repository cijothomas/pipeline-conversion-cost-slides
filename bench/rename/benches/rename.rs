//! Micro-benchmarks for the cost of renaming fields in a LogRecord.
//!
//! Models a realistic OTel-shaped LogRecord:
//!   - `name: &'static str`
//!   - `severity_num: i32`
//!   - `attributes` — 5 key/value pairs, key is &'static str, value is owned String
//!
//! Two variants of the attribute container:
//!   - `LogRecordVec` — attributes as Vec<(&'static str, String)>
//!   - `LogRecordMap` — attributes as HashMap<&'static str, String>
//!
//! For each, we measure:
//!   - rename of the top-level `name` field
//!   - rename of an attribute key (look up old key, replace with new key)
//!   - rename of an attribute value (look up by key, replace its value)
//!
//! Each operation is measured as a single record, and as a batch of 512
//! records (a realistic OTel `send_batch_size`).
//!
//! The point is to anchor the talk's claim that the transform itself is
//! negligible; the pipeline's CPU cost comes from everything *around* the
//! transform (decode, allocate, walk, re-encode, GC).
//!
//! Run with: `cargo bench --bench rename`
//!
//! ## Latest results
//!
//! 2026-06-17, Apple Silicon MacBook Pro, release build (LTO + 1 codegen unit).
//! Realistic LogRecord: `name` + `severity_num` + 5 attributes.
//!
//! ### Single record
//!
//! | Op                  | Mean      | Throughput / core |
//! |---------------------|-----------|-------------------|
//! | `rename_name`       | ~2.59 ns  | ~386 M ops/s      |
//! | `vec_rename_key`    | ~5.44 ns  | ~184 M ops/s      |
//! | `vec_rename_value`  | ~18.98 ns | ~53 M ops/s       |
//! | `map_rename_value`  | ~32.41 ns | ~31 M ops/s       |
//! | `map_rename_key`    | ~39.03 ns | ~26 M ops/s       |
//!
//! ### Batch of 512 records
//!
//! | Op                              | Mean      | Per record | Throughput / core |
//! |---------------------------------|-----------|------------|-------------------|
//! | `batch_512_rename_name`         | ~396 ns   | ~0.77 ns   | ~1.30 B records/s |
//! | `batch_512_vec_rename_key`      | ~2.49 µs  | ~4.87 ns   | ~205 M records/s  |
//! | `batch_512_vec_rename_value`    | ~10.05 µs | ~19.6 ns   | ~51 M records/s   |
//! | `batch_512_map_rename_key`      | ~15.64 µs | ~30.5 ns   | ~33 M records/s   |
//! | `batch_512_map_rename_value`    | ~17.68 µs | ~34.5 ns   | ~29 M records/s   |
//!
//! Translation: even the most expensive case (HashMap value rename in a batch)
//! lets a single core push **~29 M records/s** through the transform itself.
//! Real OTel Collector OTLP pipelines saturate a core at ~200K logs/s on
//! the same workload — the gap is decode/alloc/walk/encode, not the rename.
//!
//! Caveats:
//! - `rename_name` in a batch is implausibly fast (~0.77 ns/record) because
//!   the compiler hoists the constant write into a tight register loop with
//!   no real per-record work surrounding it. Treat as a peak number, not a
//!   realistic per-rename cost.
//! - HashMap key rename uses `remove + insert` (two hashes, two mutations).
//!   An in-place rewrite via the entry API would be marginally cheaper.
//! - Value rename allocates a fresh String per record. Allocator churn is
//!   real — that's part of the point — but in `Cow<str>` style it would be
//!   significantly cheaper.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use std::collections::HashMap;

const OLD_NAME: &str = "user.login.attempt";
const NEW_NAME: &str = "auth.login.attempt";

const OLD_KEY: &str = "exception.type";
const NEW_KEY: &str = "exception.kind";

const OLD_VALUE: &str = "java.io.IOException";
const NEW_VALUE: &str = "java.lang.RuntimeException";

const BATCH: usize = 512;

// --- LogRecord types -----------------------------------------------------

#[allow(dead_code)]
struct LogRecordVec {
    name: &'static str,
    severity_num: i32,
    attributes: Vec<(&'static str, String)>,
}

#[allow(dead_code)]
struct LogRecordMap {
    name: &'static str,
    severity_num: i32,
    attributes: HashMap<&'static str, String>,
}

fn sample_attrs() -> Vec<(&'static str, String)> {
    vec![
        ("http.method", "GET".to_string()),
        ("http.status_code", "200".to_string()),
        ("user.id", "u-12345".to_string()),
        (OLD_KEY, OLD_VALUE.to_string()),
        ("trace.sampled", "true".to_string()),
    ]
}

fn sample_vec_record() -> LogRecordVec {
    LogRecordVec {
        name: OLD_NAME,
        severity_num: 9,
        attributes: sample_attrs(),
    }
}

fn sample_map_record() -> LogRecordMap {
    LogRecordMap {
        name: OLD_NAME,
        severity_num: 9,
        attributes: sample_attrs().into_iter().collect(),
    }
}

fn sample_vec_batch() -> Vec<LogRecordVec> {
    (0..BATCH).map(|_| sample_vec_record()).collect()
}

fn sample_map_batch() -> Vec<LogRecordMap> {
    (0..BATCH).map(|_| sample_map_record()).collect()
}

// --- single-record benches ----------------------------------------------

fn bench_rename_name(c: &mut Criterion) {
    c.bench_function("rename_name", |b| {
        b.iter_batched(
            sample_vec_record,
            |mut rec| {
                rec.name = NEW_NAME;
                black_box(rec)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_vec_rename_key(c: &mut Criterion) {
    c.bench_function("vec_rename_key", |b| {
        b.iter_batched(
            sample_vec_record,
            |mut rec| {
                for (k, _) in rec.attributes.iter_mut() {
                    if *k == OLD_KEY {
                        *k = NEW_KEY;
                        break;
                    }
                }
                black_box(rec)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_vec_rename_value(c: &mut Criterion) {
    c.bench_function("vec_rename_value", |b| {
        b.iter_batched(
            sample_vec_record,
            |mut rec| {
                for (k, v) in rec.attributes.iter_mut() {
                    if *k == OLD_KEY {
                        *v = NEW_VALUE.to_string();
                        break;
                    }
                }
                black_box(rec)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_map_rename_key(c: &mut Criterion) {
    c.bench_function("map_rename_key", |b| {
        b.iter_batched(
            sample_map_record,
            |mut rec| {
                if let Some(v) = rec.attributes.remove(OLD_KEY) {
                    rec.attributes.insert(NEW_KEY, v);
                }
                black_box(rec)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_map_rename_value(c: &mut Criterion) {
    c.bench_function("map_rename_value", |b| {
        b.iter_batched(
            sample_map_record,
            |mut rec| {
                if let Some(v) = rec.attributes.get_mut(OLD_KEY) {
                    *v = NEW_VALUE.to_string();
                }
                black_box(rec)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

// --- batch-of-512 benches -----------------------------------------------

fn bench_batch_rename_name(c: &mut Criterion) {
    c.bench_function("batch_512_rename_name", |b| {
        b.iter_batched(
            sample_vec_batch,
            |mut batch| {
                for rec in batch.iter_mut() {
                    rec.name = NEW_NAME;
                }
                black_box(batch)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_batch_vec_rename_key(c: &mut Criterion) {
    c.bench_function("batch_512_vec_rename_key", |b| {
        b.iter_batched(
            sample_vec_batch,
            |mut batch| {
                for rec in batch.iter_mut() {
                    for (k, _) in rec.attributes.iter_mut() {
                        if *k == OLD_KEY {
                            *k = NEW_KEY;
                            break;
                        }
                    }
                }
                black_box(batch)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_batch_vec_rename_value(c: &mut Criterion) {
    c.bench_function("batch_512_vec_rename_value", |b| {
        b.iter_batched(
            sample_vec_batch,
            |mut batch| {
                for rec in batch.iter_mut() {
                    for (k, v) in rec.attributes.iter_mut() {
                        if *k == OLD_KEY {
                            *v = NEW_VALUE.to_string();
                            break;
                        }
                    }
                }
                black_box(batch)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_batch_map_rename_key(c: &mut Criterion) {
    c.bench_function("batch_512_map_rename_key", |b| {
        b.iter_batched(
            sample_map_batch,
            |mut batch| {
                for rec in batch.iter_mut() {
                    if let Some(v) = rec.attributes.remove(OLD_KEY) {
                        rec.attributes.insert(NEW_KEY, v);
                    }
                }
                black_box(batch)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

fn bench_batch_map_rename_value(c: &mut Criterion) {
    c.bench_function("batch_512_map_rename_value", |b| {
        b.iter_batched(
            sample_map_batch,
            |mut batch| {
                for rec in batch.iter_mut() {
                    if let Some(v) = rec.attributes.get_mut(OLD_KEY) {
                        *v = NEW_VALUE.to_string();
                    }
                }
                black_box(batch)
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

criterion_group!(
    benches,
    bench_rename_name,
    bench_vec_rename_key,
    bench_vec_rename_value,
    bench_map_rename_key,
    bench_map_rename_value,
    bench_batch_rename_name,
    bench_batch_vec_rename_key,
    bench_batch_vec_rename_value,
    bench_batch_map_rename_key,
    bench_batch_map_rename_value,
);
criterion_main!(benches);
