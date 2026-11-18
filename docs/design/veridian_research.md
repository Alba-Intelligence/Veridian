<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# If you know the reference platform of a large bank, do you kno which Julia libraries exist to reimplement it?

Yes. **the reference platform is not one library but a large bank’s proprietary, cross-asset trading/risk/analytics platform**: a distributed object data store, calculation/risk engine, grid scheduler, messaging layer, tables, workflow, and desktop applications. There is no single Julia package that reimplements it; you would assemble a Julia stack, and the hardest parts—object graph, distributed compute, production controls—would largely be custom.[^1_1][^1_2][^1_3]

## reference-platform-to-Julia map

| the reference platform capability | Julia libraries / building blocks | Caveat |
| :-- | :-- | :-- |
| Trade/deal object model, financial objects, dependency graph | Custom Julia types, `StructTypes.jl`, `UUIDs.jl`; a graph library such as `Graphs.jl` for lineage/dependencies | This is the core custom design problem; the reference platform’s deal model is notably complex. [^1_1][^1_2] |
| Market data, time series, tables | `DataFrames.jl`, `TimeSeries.jl`, `MarketData.jl`, `Arrow.jl`, `Parquet.jl`, `DuckDB.jl` | Good for analytics, but not a drop-in replacement for the reference platform’s a proprietary table type/in-memory real-time aggregation. [^1_4][^1_2] |
| Pricing and derivatives | `QuantLib.jl`, `FinancialDerivatives.jl`, `Ito.jl` | Useful starting points, but coverage, curve conventions, and production-grade calibration will need extension. [^1_5][^1_6] |
| Risk: VaR, ES, stress, sensitivities | `Distributions.jl`, `StatsBase.jl`, `Bootstrap.jl`, `ForwardDiff.jl`, `FiniteDiff.jl`, `MonteCarloMeasurements.jl` | You would build the risk aggregation, scenario framework, and P\&L attribution yourself. the reference platform is explicitly used for VaR, expected shortfall, stress, P\&L, and FRTB-related work. [^1_7][^1_8] |
| Distributed calculation / grid | `Distributed` standard library, `Dagger.jl`, `Folds.jl`, `MemVocab`/custom task graph; optionally `SlurmClusterManager.jl` or Kubernetes-based workers | the reference platform has a custom scheduler (`HUGS`) and job agent (`Bob`); Julia has primitives, not an equivalent turnkey bank grid platform. [^1_2][^1_3] |
| Messaging / distributed tables | `ZMQ.jl`, `MQTT.jl`, `Kafka.jl`, `Redis.jl`, `Arrow.jl` | the reference platform used AMPS and ZMQ-style distributed tables; Julia can integrate with these, but real-time semantics must be designed. [^1_2][^1_3] |
| Persistence / object store | `DuckDB.jl`, `SQLite.jl`, `Postgres.jl`, `Arrow.jl`, `S3.jl`; for a graph/object store, custom schema on PostgreSQL or a document/graph DB | the reference platform’s `Sandra` is an object-based data store, not merely a relational database. [^1_2] |
| Workflow, lifecycle, approvals, settlement | `BPMN`-style workflow engine or custom state machine; `Genie.jl`/`Oxygen.jl` for services, `HTTP.jl`, `Databases.jl` | This is enterprise workflow, not quant math; likely the largest non-modeling effort. [^1_2][^1_3] |
| Desktop / UI | `Genie.jl`, `PlotlyJS.jl`, `Makie.jl`, or a separate TypeScript/React front end calling Julia services | the reference platform had a globally distributed IDE and UI framework; a web front end is usually more realistic than rebuilding that in Julia. [^1_3] |
| Backtesting / strategy research | `SaguaroTrader.jl`, `TradingLogic.jl`, `MarketTechnicals.jl` | These are research/trading tools, not a front-to-back bank platform. [^1_9][^1_5] |

## Best practical stack

For a credible internal “mini reference platform,” I would start with:

- **Data layer:** PostgreSQL + `DuckDB.jl` + `Arrow.jl`/`Parquet.jl`; `DataFrames.jl` for analytics.
- **Domain layer:** custom Julia structs for instruments, trades, portfolios, curves, vol surfaces, calendars, and calculation contexts.
- **Pricing/risk:** `QuantLib.jl` for standard instrument coverage, plus custom Julia models where conventions or cross-asset behavior matter.
- **Compute:** `Distributed` + `Dagger.jl` for task graphs, with workers on Kubernetes or Slurm.
- **Services/UI:** Julia microservices via `Oxygen.jl` or `Genie.jl`; React/TypeScript UI.
- **Observability and controls:** OpenTelemetry, structured logging, audit tables, model-validation tests, and immutable calculation snapshots.


## What not to expect

Julia is strong for the numerical and analytics core: fast arrays, BLAS/LAPACK-backed linear algebra, differentiable and high-performance computation, and a growing quant-finance ecosystem. But the reference platform’s value is equally in its **platform engineering**: globally distributed object database, scheduler, dependency-graph execution, real-time aggregation, deployment, permissions, auditability, and front-to-back workflow.[^1_2][^1_3][^1_5][^1_10][^1_11]

So the honest answer is: **use Julia for the pricing/risk/data engine, but treat the reference-platform-like platform layer as a systems project**—probably with PostgreSQL/Kafka/Kubernetes and a web UI around it. The closest Julia starting points are `QuantLib.jl`, `FinancialDerivatives.jl`, `MarketData.jl`, `DataFrames.jl`, `Dagger.jl`, and `ZMQ.jl`.[^1_4][^1_5][^1_2]

<span style="display:none">[^1_12][^1_13][^1_14][^1_15][^1_16][^1_17][^1_18][^1_19][^1_20][^1_21][^1_22][^1_23][^1_24]</span>

<div align="center">⁂</div>

[^1_1]: https://digital.wpi.edu/downloads/kw52j961h?locale=en

[^1_2]: https://digital.wpi.edu/downloads/rv042v56d

[^1_3]: https://www.linkedin.com/in/kirat-singh-7468b31

[^1_4]: https://juliapackages.com/packages?dependee=pooledarrays\&order=asc\&sort=created

[^1_5]: https://github.com/orgs/JuliaQuant/repositories

[^1_6]: https://juliapackages.com/c/finance

[^1_7]: (source link withheld)

[^1_8]: (source link withheld)

[^1_9]: https://juliapackages.com/p/saguarotrader

[^1_10]: https://docs.julialang.org/en/v1/devdocs/build/build/

[^1_11]: https://julialang.org/

[^1_12]: https://juliapackages.com/packages?dependee=preferences\&sort=name\&page=65

[^1_13]: https://docs.julialang.org/en/v1/manual/faq/

[^1_14]: https://github.com/orgs/JuliaServices/repositories

[^1_15]: https://github.com/vituri/awesome-julia/blob/main/joined_text.md

[^1_16]: https://github.com/dnadlinger/julia

[^1_17]: https://juliapackages.com/packages?depth=shallow\&order=desc\&sort=name\&page=78

[^1_18]: (source link withheld)

[^1_19]: https://julia-doc-pt-br.readthedocs.io/en/latest/packages/packagelist.html

[^1_20]: (source link withheld)

[^1_21]: (source link withheld)

[^1_22]: https://www.juliapackages.com/packages?dependee=requires\&order=asc\&sort=stars\&page=62

[^1_23]: https://goodgithub.com/reports/financial-pricing-and-risk-calculation-libraries.html

[^1_24]: (source link withheld)


---

# An approach I am curious about is using elixir as platform with Julia binaries for the scientific calculations. A key strength of reference is the extreme use of memorization.

Yes—**Elixir as the platform/control plane with Julia as a numerical compute engine is a very sensible reference-platform-inspired architecture**, especially if memoization is designed as a first-class, content-addressed calculation graph rather than as ad-hoc function caching. Elixir/BEAM gives you supervision, concurrency, distribution, and operational resilience; Julia gives you the numerical performance and model-authoring ergonomics. Elixir’s `Nebulex` supports local, partitioned, multi-level, replicated, and coherent distributed cache topologies, which maps well to the “near cache + shared calculation cache” pattern.[^2_1][^2_2][^2_3]

## The key design shift

the reference platform’s strength is not merely “cache function results.” It is that a calculation is a **node in a dependency graph**, identified by its inputs, parameters, model version, market-data snapshot, and calculation context. When an input changes, the system invalidates only the affected downstream nodes and recomputes them.[^2_4][^2_5]

In your design:

- **Elixir owns:** workflow, jobs, permissions, audit, service APIs, scheduling, cache coordination, invalidation, observability.
- **Julia owns:** pricing, calibration, risk, P\&L, simulation, and heavy numerical kernels.
- **The shared contract owns:** deterministic calculation IDs, input fingerprints, result schemas, versioning, and invalidation semantics.

That separation avoids putting large numerical arrays through the BEAM and avoids making Julia a long-lived stateful service unless you deliberately want it to be.

## Memoization architecture

Use a **content-addressed memoization key**:

```text
calc_id = hash(
  function_id,
  function_version,
  input_object_ids,
  input_value_hashes,
  market_data_snapshot_id,
  model_config_hash,
  calculation_context_hash
)
```

Then store:

```text
calc_id -> {
  result_ref,          # Arrow file, Parquet file, Redis blob, or Julia process memory
  result_schema,
  dependencies,        # parent calc_ids / input object IDs
  computed_at,
  ttl_or_as_of,
  status               # computing | complete | failed | invalidated
}
```

This gives you reference-platform-like behavior:

- **Reuse:** the same trade, market snapshot, and parameters produce the same calculation ID.
- **Incremental recomputation:** changing one curve affects only calculations that depend on it.
- **Parallelism:** independent nodes can run concurrently.
- **Auditability:** every result has a reproducible provenance key.
- **Partial failure recovery:** failed nodes can be retried without recomputing the whole portfolio.


## Cache layers

| Layer | Where it lives | Best for | Julia/Elixir libraries |
| :-- | :-- | :-- | :-- |
| L0: process-local hot cache | Julia worker | Repeated scalar/curve lookups within one calculation | Julia `Dict`, `LRUCache`, `Memoize.jl` |
| L1: worker cache | Julia worker / local disk | Recently used curves, surfaces, calibration results | `Arrow.jl`, `JLD2.jl`, local mmap files |
| L2: Elixir near cache | Elixir node | Small metadata, calculation status, dependency graph, IDs | `Cachex`, `Nebulex` with Cachex adapter [^2_6][^2_3] |
| L3: distributed calculation cache | Elixir cluster / Redis | Cross-node result reuse and coordination | `Nebulex` partitioned or multilevel topology [^2_1][^2_2][^2_3] |
| L4: durable result store | PostgreSQL + object store | Audit, reproducibility, restart recovery, historical as-of results | `Postgrex`, S3/MinIO, Arrow/Parquet |
| L5: immutable input snapshots | Object store / database | Market data, trade state, model configs | Content hashes + versioned snapshots |

Do **not** make Elixir the primary store for large numerical arrays. Keep ETS/Cachex for IDs, statuses, graph edges, and small metadata; keep tensors, curves, and simulation paths in Julia memory, Arrow files, Parquet, or an object store. Arrow is explicitly designed as a language-independent columnar format with IPC support, and Julia’s `Arrow.jl` implements its IPC reader/writer and file/stream interfaces.[^2_7][^2_8][^2_9]

## Elixir-side libraries

- **`Nebulex`** — the strongest foundation for a reference-platform-like cache abstraction: local, partitioned, multi-level, replicated, and coherent invalidation topologies.[^2_2][^2_1]
- **`Cachex`** — good ETS-backed local cache with expiration, limits, hooks, and warmers; useful as L1/L2 or as the local component of a Nebulex topology.[^2_3][^2_10]
- **`memoize`** — useful for simple Elixir-side function memoization, but too shallow for financial calculation graphs.[^2_6][^2_11]
- **`Broadway` / `GenStage`** — market-data ingestion, event-driven invalidation, and backpressure.
- **`Oban`** — durable job queue for scheduled risk runs, EOD calculations, calibration, and retries.
- **`Horde`** — distributed supervision/registry if you run Julia worker coordinators as part of the Elixir cluster.
- **`Postgrex` + `Ecto`** — calculation ledger, dependency graph, audit, and metadata.
- **`Broadway` + Kafka** — market-data events and invalidation events at scale.


## Julia-side libraries

- **`Distributed`** — Julia’s built-in multi-process model; useful if Julia workers are managed directly.
- **`Dagger.jl`** — task-graph execution; a natural fit for dependency-aware calculations.
- **`Arrow.jl`** — zero-copy-friendly columnar interchange and IPC with Elixir or other services.[^2_8][^2_9]
- **`QuantLib.jl`**, `FinancialDerivatives.jl`, `Ito.jl` — pricing/model starting points.
- **`ForwardDiff.jl` / `FiniteDiff.jl`** — sensitivities and calibration.
- **`JLD2.jl`** — convenient Julia-native persistence, though less interoperable than Arrow/Parquet.
- **`PackageCompiler.jl`** — build Julia into a standalone executable or sysimage so deployment does not depend on a full Julia development environment.


## Recommended process boundary

A good first version is:

```text
Browser / internal apps
        |
   Elixir Phoenix API
        |
 Calculation Orchestrator (Elixir)
  - resolves dependency graph
  - checks content-addressed cache
  - schedules missing nodes
  - coordinates invalidation
        |
  Julia Compute Workers
  - stateless HTTP/gRPC or queue workers
  - receive compact job specs
  - load inputs from object store / DB
  - return result references, not huge payloads
        |
 PostgreSQL + S3/MinIO + Arrow/Parquet
```

The Julia worker should receive a small, explicit job:

```json
{
  "calc_id": "sha256:...",
  "function": "swap_pv",
  "function_version": "3.2.1",
  "trade_ref": "s3://objects/trade/...",
  "market_snapshot": "2026-11-13T00:00:00Z",
  "curve_refs": ["s3://objects/curve/..."],
  "model_config_ref": "s3://objects/model/...",
  "result_ref": "s3://results/..."
}
```

It returns a compact completion event containing the result reference, diagnostics, timing, and dependency hashes. This makes Julia workers horizontally scalable and makes the memoization ledger authoritative in Elixir/PostgreSQL.

## Where it can fail

The main risks are:

- **Non-deterministic inputs:** timestamps, random seeds, floating-point reduction order, and unordered map iteration can break cache identity.
- **Implicit dependencies:** a Julia function reading global state, a database directly, or an environment variable will silently invalidate the graph.
- **Mutable objects:** trade amendments and market-data corrections need immutable versioned snapshots, not in-place mutation.
- **Cache stampede:** many requests for the same missing calculation must elect one computation, not launch hundreds of Julia jobs.
- **Invalidation correctness:** a changed curve must invalidate all dependent PVs, risks, hedges, and reports—but not unrelated calculations.
- **Serialization overhead:** passing Julia arrays through JSON is usually a mistake; use Arrow, Parquet, or object-store references.
- **Long-lived Julia state:** stateful Julia workers can be fast but complicate upgrades, failover, and reproducibility. Start stateless; add a controlled in-process cache later.


## A practical rule

Use **Elixir for the memoization system of record**, and **Julia for the memoized computation**. In other words, Elixir should know *what was calculated, from what inputs, under which version, and what depends on it*; Julia should know *how to calculate it quickly*. That division preserves the reference-platform-like benefit—extreme reuse of intermediate calculations—without trying to recreate the reference platform’s entire proprietary object model in either language.[^2_5][^2_4]

<span style="display:none">[^2_12][^2_13][^2_14][^2_15][^2_16][^2_17]</span>

<div align="center">⁂</div>

[^2_1]: https://github.com/elixir-nebulex/nebulex

[^2_2]: https://github.com/elixir-nebulex/nebulex_distributed

[^2_3]: https://github.com/elixir-nebulex/nebulex_adapters_cachex

[^2_4]: https://digital.wpi.edu/downloads/rv042v56d

[^2_5]: https://digital.wpi.edu/downloads/kw52j961h?locale=en

[^2_6]: https://elixir-toolbox.dev/projects/performance/caching

[^2_7]: https://arrow.apache.org/docs/25.0/status.html

[^2_8]: https://github.com/JuliaCN/arrow-julia/blob/main/docs/dev/core-README.md

[^2_9]: https://arrow.apache.org/docs/12.0/

[^2_10]: https://elixir-observer.com/packages/cachex

[^2_11]: https://elixir-observer.com/categories/caching

[^2_12]: https://github.com/elixir-nebulex

[^2_13]: https://elixir-observer.com/packages/nebulex_adapters_cachex

[^2_14]: https://github.com/cabol/nebulex

[^2_15]: https://github.com/elixir-nebulex/nebulex/blob/main/lib/nebulex/cache.ex

[^2_16]: https://elixir.libhunt.com/categories/667-caching

[^2_17]: https://github.com/abs-tudelft/arrow


---

# Compare Nebulex with a content-addressed graph

**Nebulex is a cache; a content-addressed graph is a computation model.** For a reference-platform-like system, use the graph to decide *what must be computed and when it is valid*, and use Nebulex as one of the fast storage/lookup layers beneath it. Nebulex’s partitioned and multilevel adapters provide distributed and near-cache topologies, while its coherent adapter provides local reads with cluster-wide invalidation events.[^3_1][^3_2][^3_3]

## Core distinction

| Aspect | Nebulex | Content-addressed graph |
| :-- | :-- | :-- |
| Primary abstraction | Key-value cache entries | Calculation nodes, dependencies, and result hashes |
| Cache key | Usually an application-defined key, often with TTL | Deterministic hash of function, version, inputs, config, and context |
| Invalidation | TTL, explicit delete, or distributed invalidation events | Automatic: a changed input changes its hash, invalidating descendants |
| Dependency awareness | None built in | Central: each node records its parents/inputs |
| Reuse | Reuses a stored value under the same key | Reuses any calculation whose full input fingerprint matches, even across portfolios or requests |
| Correctness model | “This entry has not expired or been deleted” | “This result is provably derived from these exact inputs and code version” |
| Failure recovery | Re-fetch or recompute the missing key | Retry only failed/missing nodes; unaffected completed nodes remain valid |
| Best role in your stack | Hot result/status/metadata cache | Source of truth for calculation lineage, scheduling, and invalidation |

A content-addressed build system maintains both a content cache and a memo table mapping executed tasks and their input/output hashes, allowing it to bypass execution when dependencies’ hashes predict the result. That is precisely the pattern you want for financial calculations.[^3_4]

## Nebulex’s role

Nebulex is excellent for **high-throughput lookup and distribution**, but it does not inherently know that `swap_pv(trade_42, curve_2026-11-13)` depends on `discount_curve_EUR`, `forecast_curve_EUR`, and `vol_surface_EUR`. It can store the result under a key and invalidate it, but it cannot derive the set of keys to invalidate from a changed input.[^3_3][^3_5]

Its distributed adapters are useful as:

- **L1 local/near cache:** each Elixir node keeps recently used calculation metadata or small results.
- **L2 partitioned cache:** calculation results or metadata are sharded across nodes; Nebulex describes this as a single-hop operation to the owning node.[^3_2][^3_1]
- **Coherent cache:** each node keeps an independent local cache, while writes broadcast invalidation events so other nodes evict stale entries.[^3_6][^3_3]
- **Multilevel cache:** L1 local plus L2 partitioned, which is the classic near-cache pattern.[^3_7][^3_8][^3_2]


## Content-addressed graph’s role

The graph should be the **authoritative calculation ledger**:

```text
market_snapshot_2026-11-13
├── eur_discount_curve
│   └── eur_forward_curve
│       └── swap_pv(trade_42)
│           ├── delta_EUR
│           ├── vega_EUR
│           └── portfolio_pnl
└── eur_vol_surface
    └── swap_vega(trade_42)
```

Each node stores something like:

```elixir
%CalculationNode{
  id: "sha256:...",
  function: "swap_pv",
  function_version: "3.2.1",
  inputs: %{
    "trade" => "sha256:...",
    "discount_curve" => "sha256:...",
    "forward_curve" => "sha256:...",
    "market_snapshot" => "sha256:..."
  },
  result_ref: "s3://results/...",
  result_hash: "sha256:...",
  status: :complete,
  dependencies: ["sha256:...", "sha256:..."]
}
```

When the EUR discount curve changes, its content hash changes. The orchestrator walks the reverse dependency edges and marks only the affected nodes stale: the forward curve, affected swap PVs, and their risk/report descendants. It does **not** invalidate unrelated trades or calculations.

## How they fit together

A practical flow is:

1. **Elixir receives a request**—for example, “compute portfolio risk as of 13:00.”
2. **The graph engine resolves inputs** into immutable, content-hashed objects: trade snapshots, market-data snapshot, curves, surfaces, model configs, and code/model versions.
3. **It checks the durable memo table** in PostgreSQL for complete nodes.
4. **For a cache hit, it checks Nebulex** for a hot result reference or small derived value.
5. **For a miss, it schedules Julia** to compute only the missing nodes.
6. **Julia writes the result** to object storage/Arrow/Parquet and returns a result reference plus hash.
7. **Elixir records the completed node**, its dependencies, and result hash.
8. **On a market-data event, the graph engine invalidates descendants**, while Nebulex evicts corresponding hot entries.

This means Nebulex answers, “Is this result immediately available nearby?” The graph answers, “Is this result semantically valid for this exact set of inputs and model version?”

## What Nebulex cannot replace

Do not rely on Nebulex alone for:

- **Dependency-aware invalidation:** it has no native calculation dependency graph.
- **Provenance and reproducibility:** a cache key with a TTL is not an audit-grade derivation record.
- **Cross-cutting reuse:** a graph can recognize that two apparently different requests share an identical curve calibration or risk calculation.
- **Partial recomputation:** Nebulex may evict a result; the graph knows whether that result is still valid and can restore it from durable storage.
- **Versioned model changes:** changing a Julia pricing function should change the function version and therefore every downstream calculation ID.


## Recommended combination

Use this layering:

```text
Content-addressed graph + PostgreSQL ledger
              |
        Nebulex caches
     /        |        \
L1 local   L2 partitioned   Coherent invalidation
              |
       Julia compute workers
              |
   Arrow/Parquet + object store
```

- **PostgreSQL:** durable graph, calculation status, audit trail, and job state.
- **Nebulex:** high-speed metadata/result-reference cache and distributed invalidation.
- **Julia:** deterministic calculation execution.
- **Object store/Arrow:** immutable inputs and large result payloads.

In short: **Nebulex makes the graph fast; the content-addressed graph makes Nebulex correct.** For your Elixir-plus-Julia the reference platform reimplementation, the graph is mandatory; Nebulex is a strong optional accelerator.[^3_3][^3_4]

<span style="display:none">[^3_10][^3_11][^3_12][^3_13][^3_14][^3_15][^3_16][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: https://nebulex.hexdocs.pm/2.0.0/Nebulex.Adapters.Partitioned.html

[^3_2]: https://nebulex.hexdocs.pm/getting-started.html

[^3_3]: https://hexdocs.pm/nebulex_distributed/Nebulex.Distributed.html

[^3_4]: https://www.cambridge.org/core/services/aop-cambridge-core/content/view/097CE52C750E69BD16B78C318754C7A4/S0956796820000088a.pdf/build-systems-a-la-carte-theory-and-practice.pdf

[^3_5]: https://github.com/elixir-nebulex/nebulex

[^3_6]: https://github.com/cabol/nebulex/blob/master/CHANGELOG.md

[^3_7]: https://nebulex.hexdocs.pm/2.6.2/getting-started.html

[^3_8]: https://github.com/elixir-nebulex/nebulex_adapters_cachex/blob/main/README.md

[^3_9]: https://nebulex.hexdocs.pm/2.5.2/Nebulex.Adapters.Multilevel.html

[^3_10]: https://nebulex.hexdocs.pm/3.0.0-rc.2/nbx-adapters.html

[^3_11]: https://nebulex.hexdocs.pm/2.6.4/Nebulex.Cache.html

[^3_12]: https://nebulex.hexdocs.pm/1.0.0-rc.3/getting-started.html

[^3_13]: https://nebulex.hexdocs.pm/2.0.0-rc.1/Nebulex.Adapters.Partitioned.html

[^3_14]: https://github.com/elixir-nebulex/nebulex_distributed/blob/main/README.md

[^3_15]: https://github.com/elixir-nebulex/nebulex_distributed

[^3_16]: https://github.com/elixir-nebulex/nebulex_adapters_cachex

