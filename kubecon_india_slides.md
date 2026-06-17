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
- Approver - OTel Specification, OTel .NET and OTel Arrow

---

# What Pipelines Are For

> *Anything between the moment a telemetry signal is produced and the moment it lands in a queryable state in some backend — that's the pipeline.*

Pipelines do real, useful work in that middle:

<v-clicks>

- **Enrich**
- **Redact**
- **Filter & sample**
- **Route**
- **Batch & compress**
- **Transform**

</v-clicks>

<v-click>

Most of these are **simple per-attribute operations** applied across a batch.

Let's pick the simplest one — **renaming an attribute** — and see what it actually costs.

</v-click>

---

# Renaming an Attribute Should Be Cheap

Measured on a realistic `LogRecord` shape ([bench/rename](./bench/rename/benches/rename.rs)):

<v-clicks>

| Where | Cost per record | Records / sec / core |
|---|---:|---:|
| **Top-level field on a record** | ~2.6 ns | ~385 M |
| **An attribute inside a record** | ~30 ns | ~33 M |
| **Across a batch of 512 records** | ~35 ns | ~29 M |

</v-clicks>

<v-click>

So the actual rename cost is **negligible**.

</v-click>

<v-click>

…then why does the same workload at just **200K logs/s** saturate a core in a real pipeline?

</v-click>

---

# So Why Do Real Pipelines Burn So Much CPU?

<v-clicks>

- The work the pipeline *says* it's doing — rename one attribute — costs almost nothing.
- Yet at modest log rates (100–200K logs/s), that one rule can dominate CPU.
- So where is all that CPU actually going?

</v-clicks>

---

# Start With the Easiest Case: Passthrough

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

The pipeline keeps OTLP's row-oriented shape **internally**, so this conversion is mandatory at every hop. **Most of the CPU is gone before any processing happens.**

In a local passthrough run, **~6% of CPU goes to protobuf decode**, and another **~15% to the allocations and GC** those decodes cause. So **~20% of CPU is paid before any processing happens** — purely on shape conversion.

_(Exact share depends on rate, payload, and what else the pipeline is doing. The point: it's never zero.)_

</v-click>

---

# Now Add One Transform

One rename rule: `exception.type → exception.kind`. Each new rule **stacks** on top.

<v-click>

Local sweep, unbounded OTLP load, single CPU core:

| Rename ops | Throughput (logs/s) | SUT CPU |
|---:|---:|---:|
| **0** (passthrough) | **421K** | 54% |
| 1 | 342K | 71% |
| 2 | 289K | 77% |
| **4** | **213K** | 85% |

</v-click>

<v-click>

Four trivial renames → **throughput drops ~50%**.

The first rule sits on top of an expensive decode/encode; every additional one stacks on the same per-row, allocation-heavy path.

</v-click>

---

# Three Things Are Going On

<v-clicks>

1. **Conversion at every hop** — protobuf bytes → object graph → bytes. Mandatory, regardless of what happens in between.
2. **GC pressure** — every batch allocates resource / scope / record / attribute objects. Every batch becomes garbage. Allocator and collector burn CPU.
3. **Per-row work** — to rename one attribute, the processor walks every record in the batch, one at a time.

</v-clicks>

<v-click>

What if the in-memory representation made all three of these go away?

</v-click>

---

# It's Not Just the Collector — SDKs Pay It Too

Same cost model, smaller scale. Every SDK exporter does:
`SDK type → protobuf struct → byte[]`

Per log record:

| SDK | Total |
|---|---:|
| **.NET** (skips the struct hop) | ~194 ns |
| **Rust** | ~510 ns |
| **Go** | ~887 ns |

<v-click>

Sub-microsecond per record — small per-event, but it's there in **every** application emitting telemetry, on every host, all the time.

</v-click>

<v-click>

The pipeline's tax is the dramatic one. **The SDK pays a quieter version of the same tax.**
This is a system-wide problem, not a collector problem.

</v-click>

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

---

# OTAP: OpenTelemetry Protocol with Apache Arrow

<img src="./obssummit_assets/otap-tables.svg" class="h-96 mx-auto" />

---

# OTAP In, OTAP Out: No Conversion at All

<img src="./obssummit_assets/decode-paths.svg" class="h-80 mx-auto" />

<v-clicks>

- Wire bytes **map directly** to Arrow column buffers — no per-record decode
- Processors operate on those batches as **columns**, not as per-record object graphs
- No per-record allocation. No GC churn.

</v-clicks>

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

Same workload — rename rules added one at a time:

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

_(200K logs/s, ~300 B/log)_

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

---

# Thank You & Q&A

**Cijo Thomas** · [@cijothomas](https://github.com/cijothomas) · Microsoft

[github.com/open-telemetry/otel-arrow](https://github.com/open-telemetry/otel-arrow)  
[CNCF Slack #otel-arrow](https://cloud-native.slack.com/archives/C02JADSFY8Y)
