---
theme: default
title: The Invisible Tax - How Data Format Conversions Drive Up Telemetry Pipeline Costs
presenter: true
---

<!-- markdownlint-disable MD022 MD025 MD033 MD040 MD060 -->

# The Invisible Tax
## How Data Format Conversions Drive Up Telemetry Pipeline Costs

**Cijo Thomas** · Microsoft

[KubeCon + CloudNativeCon India 2026](https://kccncind2026.sched.com/event/2IW2j/the-invisible-tax-how-data-format-conversions-drive-up-telemetry-pipeline-costs-cijo-thomas-microsoft)

---

# Speaker

**Cijo Thomas** · Microsoft

- Maintainer, OTel Rust
- Approver — OTel Specification, OTel .NET and OTel Arrow

---

# What Pipelines Are For

> *Anything between the moment a telemetry signal is produced and the moment it lands in a queryable state in some backend — that's the pipeline.*

Pipelines do real, useful work between the app and the backend:

<v-clicks>

- **Transport**
- **Batch & compress**
- **Filter & sample**
- **Enrich**
- **Redact**
- **Route**
- **Transform**

</v-clicks>

<v-click>

Let's pick the simplest one — **renaming an attribute** — and see what it actually costs.

</v-click>

---

# Renaming an Attribute Should Be Cheap

<div grid="~ cols-2 gap-4" class="mt-2">

<div>

**before**

```rust
LogRecord {
  name: "user.login.attempt",
  severity_num: 9,
  attributes: [
    ("http.status_code", "200"),
    ("user.id", "u-12345"),
    ("exception.type",
     "java.io.IOException"),
  ],
}
```

</div>

<div>

<v-click>

**after**

```rust
LogRecord {
  name: "user.login.attempt",
  severity_num: 9,
  attributes: [
    ("http.status_code", "200"),
    ("user.id", "u-12345"),
    ("exception.kind",  // ← renamed
     "java.io.IOException"),
  ],
}
```

</v-click>

</div>

</div>

<v-click>

This rename takes **~30 ns** per record. A single CPU core, in a tight loop, can do **~30 million per second**.

</v-click>

<v-click>

So the actual rename cost is **negligible**.

</v-click>

<v-click>

…but anyone who has run a real telemetry pipeline knows a single core gets nowhere close to that.

</v-click>

---

# Start With the Easiest Case: Passthrough

Some cost is unavoidable — real pipelines move bytes over the network and talk gRPC/HTTP. **We're not counting that.** Where is the *rest* of the CPU going?

A collector with **nothing in the middle** — OTLP in, OTLP out, zero processors.

<v-click>

No transforms. No business logic. Just forward the bytes.
**This should be blazing fast.**

</v-click>

<v-click>

…except it isn't. For every batch the pipeline still has to:

- **Decode** protobuf bytes → allocate a full object graph
  (resource → scope → records → attributes — one object per field)
- …do nothing in the middle…
- **Re-encode** the object graph back to bytes
- Throw away every allocated object — GC and allocator churn

</v-click>

<v-click>

The pipeline keeps OTLP's row-oriented shape **internally**, so this conversion is mandatory at every hop.

Depending on the workload, a good chunk of CPU goes into conversion and the allocation/GC churn it causes — and that's the cost you pay **before any useful processing happens**.

</v-click>

---

# Now Add One Transform

OK — that was before any processing. Let's add some.

One rename rule: `exception.type → exception.kind`.

<v-click>

Each new rule **stacks** on the same per-row, allocation-heavy path. Throughput drops; CPU climbs.

</v-click>

<v-click>

We'll measure how much in a few slides — once we've seen *why* it stacks.

</v-click>

---

# It's Not Just the Collector — SDKs Pay It Too

Most SDK exporters do the same shape conversion:

`SDK record → protobuf struct → byte[]`

Two conversions per record, on every host emitting telemetry.

<v-click>

Measured cost per log record:

| SDK | Conv 1 (SDK → struct) | Conv 2 (struct → bytes) | **Total** |
|---|---:|---:|---:|
| **Rust** | 395 ns | 114 ns | **~510 ns** |
| **Go** | 281 ns | 598 ns | **~887 ns** |
| **.NET** (skips Conv 1) | — | — | **~194 ns** |

_.NET emits the protobuf struct directly from the SDK — proof that Conv 1 is avoidable, not free._

</v-click>

<v-click>

Sub-microsecond per record — small per-event, but it's in **every** application emitting telemetry, on every host, all the time.

</v-click>

<v-click>

The pipeline's tax is the dramatic one. **The SDK pays a quieter version of the same tax.**
This is a system-wide problem, not a collector problem.

</v-click>

---

# What's Actually Going On — In Both Cases?

Whether it's the Collector or an SDK exporter, the cost has the same three shapes:

<v-clicks>

1. **Conversion at every hop** — protobuf bytes → object graph → bytes. Mandatory, regardless of what happens in between.
2. **GC pressure** — every batch allocates resource / scope / record / attribute objects. Every batch becomes garbage. Allocator and collector burn CPU.
3. **Per-row work** — to rename one attribute, the processor walks every record in the batch, one at a time.

</v-clicks>

<v-click>

What if the in-memory representation made all three of these go away?

</v-click>

<!--
Speaker note: Hold on to these three — we'll come back to them when we compare
against Arrow.
-->

---

# This Is a Structural Problem

Every OTel component has its own native in-memory representation:

<v-clicks>

- SDKs have SDK types
- The Collector has Go pdata
- Backends have their own ingestion schema

</v-clicks>

<v-click>

So conversion happens **at every boundary** — not because anyone designed it that way, but because nobody agreed on a shared shape.

The wire format (OTLP protobuf) is *only* a wire format. It's nobody's in-memory home.

</v-click>

---

# What Would the Fix Look Like?

Wire transport is unavoidable — bytes have to cross processes and machines.
So we need an **in-memory representation** that:

<v-clicks>

- **Maps cheaply to/from the wire** — minimal decode and encode work at boundaries
- **Fits how pipelines actually work** — bulk per-column ops over batches, not per-record walks
- **Is language-neutral** — SDK in Rust, processor in Go, backend in Java all share the same shape with no conversion

</v-clicks>

---

# Apache Arrow, OTAP, and the Dataflow Engine

- **Apache Arrow** — a columnar, batch-oriented in-memory format. Same layout on the wire and in memory.
- **OTAP** — *OpenTelemetry Protocol with Apache Arrow*. A 100%-compatible OTLP alternative that carries telemetry as Arrow record batches.
- **Dataflow Engine (DFE)** — a thread-per-core Rust runtime that uses **OTAP as its in-memory representation**, so processors operate directly on Arrow batches.

<v-click>

The combination is what kills all three costs at once: no conversion at the boundary, no per-record allocation, and bulk ops vectorize across columns.

</v-click>

[github.com/open-telemetry/otel-arrow](https://github.com/open-telemetry/otel-arrow)

---

# OTLP: OpenTelemetry Protocol

<img src="./obssummit_assets/otlp-bytes.svg" class="h-96 mx-auto" />

<div class="text-center text-sm opacity-75 mt-2">

_Nested protobuf — opaque until decoded, walked one record at a time._

</div>

<!--
Speaker notes:
- Here's what one OTLP batch actually looks like on the wire: a packed protobuf
  message — every record's resource, scope, attributes, body, all nested and
  length-prefixed.
- Compact and well-specified, but completely opaque until you decode it. You
  can't read, rename, or filter anything until you've parsed every length prefix
  and materialized the full nested object tree in memory.
- And every time it crosses a process boundary, the receiver decodes and the
  sender re-encodes. That's the tax we just measured.
-->

---

# OTAP: OpenTelemetry Protocol with Apache Arrow

<img src="./obssummit_assets/otap-tables.svg" class="h-96 mx-auto" />

<div class="text-center text-sm opacity-75 mt-2">

_Same data — columnar tables. Wire layout == memory layout._

</div>

<!--
Speaker notes:
- Same telemetry, restructured. Instead of one packed byte tape, OTAP arranges
  it as a few columnar tables: one for logs, one for attributes, plus the
  relationships between them.
- The wire bytes here are Arrow IPC — but unlike protobuf, the wire layout is
  the same shape as the in-memory layout. The receiver doesn't have to walk
  every record to extract values; the column buffer is already there.
- And it's batch-oriented: a million records share one column. That's why
  filters, renames, and other bulk ops can run as column operations instead of
  a per-record walk.
-->

---

# OTAP In, OTAP Out: No Conversion at All

<img src="./obssummit_assets/decode-paths.svg" class="h-80 mx-auto" />

<v-clicks>

- Wire bytes **map directly** to Arrow column buffers — no per-record decode
- Processors operate on those batches as **columns**, not as per-record object graphs
- No per-record allocation. No GC churn.

</v-clicks>

<!--
Speaker notes:
- Left side: an OTLP pipeline. Every time bytes arrive, unmarshal — heap-
  allocate the full object graph. To send: marshal back to bytes. Every hop
  pays both.
- Right side: an OTAP pipeline. Wire bytes parse straight into Arrow column
  buffers — and out the same way. No per-record decode, no per-record
  allocation.
- Same source data, same destination, but one path pays the conversion tax
  twice per hop and the other pays it zero times.
- (Honesty caveat if asked: "zero copy" is slightly aspirational — there's a
  small Flatbuffers metadata parse per batch, but no per-record work.)
-->


---

# Same Runtime. Only the Protocol Changes.

Both rows are the **same DFE**, on the **same cores**. Only the wire format differs:

<v-click>

| Wire protocol | Throughput @ 1 core |
|---|---:|
| **OTLP** in/out (decode + convert at the boundary) | 121K logs/s |
| **OTAP** in/out (Arrow end to end) | **2.47M logs/s — ~20×** |

</v-click>

<v-click>

Isolating just the wire protocol: avoiding boundary conversion is worth **~20×**.

</v-click>

_(The OTAP run is load-generator-limited — real ceiling is higher.)_

---

# Each Rule Costs the Collector. DFE Barely Notices.

Same workload — rename rules added one at a time. Watch the **per-added-op** row:

<v-click>

| Rename ops | OTel Collector (OTLP) | DFE (OTAP) |
|---:|---:|---:|
| 1 | ~81% CPU | **6.4%** CPU |
| 4 | ~92.5% CPU | **6.6%** CPU |
| **per added op** | **+3.75%** | **~+0.07%** |

</v-click>

<v-click>

Each rule on the Collector pays the **per-row, allocation-heavy tax**.
DFE operates on **columns** — adding rules is nearly free.

</v-click>

_(200K logs/s, ~300 B/log. DFE absolute baseline is ~6% at this load; the story is the per-rule delta.)_

<!--
Speaker note: Here's the data I promised earlier. Don't get hung up on Collector
starting at 81% vs DFE at 6% — different runtimes, different absolute baselines.
The honest comparison is the bottom row: each added rule costs the Collector
~3.75% and DFE essentially nothing.
-->

---

# Imagine: Telemetry Born in Arrow

<v-clicks>

- SDKs emit Arrow batches directly — no protobuf step at the app
- Pipelines stay in Arrow end to end — no per-hop conversion
- Backends ingest Arrow — many analytics engines already speak it natively

</v-clicks>

<v-click>

One representation, from source through every hop to query.
No tax. No GC churn. No translation between hops.

That's the destination.

</v-click>

---

# Get Involved

OTel Arrow is **work-in-progress** — not production-ready yet.

<v-clicks>

- If you're building a query/processing engine, consider **Arrow as your in-memory representation**
- If you have a choice of sending OTLP or OTAP, choose the protocol that **costs the least end-to-end**
- If you are a telemetry backend, **offer OTAP as an alternative to OTLP** to lower your and your user's conversion costs

</v-clicks>

[github.com/open-telemetry/otel-arrow](https://github.com/open-telemetry/otel-arrow) · [CNCF Slack #otel-arrow](https://cloud-native.slack.com/archives/C02JADSFY8Y)

Deep dive: [OTel-Arrow Phase 2 blog](https://opentelemetry.io/blog/2026/otel-arrow-phase-2/)

---

# Where We Are

<v-clicks>

- The conversion tax is real, structural, and applies to **every** OTel component — SDKs, collectors, backends.
- The fix is a **shared, columnar, language-neutral in-memory format**. Apache Arrow is the obvious candidate.
- OTel Arrow is exploring exactly this. Early results: **~20× on the wire, near-free transforms** on the Arrow-native runtime.
- It's **early** — incubation, not production. The interesting work is just starting.

</v-clicks>

<v-click>

_Like a currency conversion fee: invisible per transaction, painful at scale — and worth removing._

</v-click>

---

# Thank You & Q&A

**Cijo Thomas** · [@cijothomas](https://github.com/cijothomas) · Microsoft

[github.com/open-telemetry/otel-arrow](https://github.com/open-telemetry/otel-arrow)  
[CNCF Slack #otel-arrow](https://cloud-native.slack.com/archives/C02JADSFY8Y)
