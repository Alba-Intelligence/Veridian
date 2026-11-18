# Size targets and the laptop spike (D-043)

Status: accepted 2026-11-14. Figures are planning assumptions for a
mid-sized bank trading book, to be replaced by the target bank's numbers.

## 1. Size targets

### Portfolio (design point, and 10x stress point)

| Item | Design | Stress (10x) |
|---|---|---|
| Vanilla IRS | 50,000 | 500,000 |
| Bonds (bullet and callable) | 20,000 positions | 200,000 |
| Equity calls (European and American) | 5,000 | 50,000 |
| Legal entities | 3, plus the consolidated group | 10 |
| Books | 200 | 2,000 |
| Currencies | 10 | 20 |

### Calculation graph per end-of-day run

Each position appears in two FRTB perimeters (its legal entity and the
consolidated group), and has one valuation node plus one sensitivity node
per perimeter (D-036, D-039).

| Item | Design | Stress |
|---|---|---|
| Valuation nodes | 75,000 | 750,000 |
| Sensitivity nodes | 150,000 | 1,500,000 |
| Market and shocked market objects | ~5,000 | ~20,000 |
| Aggregation and DRC nodes | ~5,000 | ~20,000 |
| **Total nodes** | **~235,000** | **~2,300,000** |
| Revaluations inside sensitivity nodes (about 50 each) | ~7.5 million | ~75 million |

### Time and throughput

| Target | Value |
|---|---|
| End-of-day run, cut-off to results ready for sign-off | 2 hours at stress, on grid hosts |
| Ledger: node completions recorded | 1,000 per second sustained (design needs ~35/s over 2 h; stress ~320/s; 3x headroom) |
| Memo lookup by calc_id with 100 million nodes stored | under 2 ms at the 99th percentile |
| Dispatch overhead per job (queue, Arrow hand-off, ledger write) | under 5 ms median, under 20 ms at the 99th percentile |
| Julia worker ready after start, with a precompiled system image | under 30 s; first job after ready under 1 s extra |
| Grid allocation granted to host serving | under 2 minutes after Slurm grants it |
| Desk view of 1,000 swaps, market objects already computed | under 5 s (D-038) |
| What-if of one hypothetical trade | under 2 s |
| Concurrent interactive users | 50 traders, 10 reviewers |

### Storage growth

| Item | Design per business day | Per year (260 days) |
|---|---|---|
| Ledger rows (node, step, payload record, audit event) | ~1.2 million | ~300 million |
| Result payloads (Arrow, ~20 KB average) | ~5 GB | hot 7 days ~35 GB, cold 30 days ~150 GB (D-005) |
| Reported figures kept 10 years (D-038) | ~50,000 | ~13 million |
| Trade versions (about 5% of trades change daily) | ~4,000 | ~1 million |

## 2. The riskiest assumption

A vanilla IRS sensitivity node does about 50 revaluations at tens of
microseconds each: **a few milliseconds of compute**. If dispatch overhead
is also a few milliseconds, half the grid's time is overhead, and the
"one node per position" rule (D-039) must give way to block nodes (many
small positions per node, sharing shocked curves). The spike measures this
first, because it decides the shape of the graph.

## 3. Spike plan (8 working days, laptop only, no cloud)

Everything runs in the devenv environment as code (D-037): PostgreSQL, an
S3-compatible object store, Erlang/Elixir, Julia, and a simulated Slurm
cluster (one controller and three simulated nodes).

| Days | Work |
|---|---|
| 1-2 | Environment: devenv with PostgreSQL, object store, Elixir, Julia and simulated Slurm; `devenv up` starts everything. |
| 3-4 | Thin vertical path: minimal ledger tables (requests, steps, nodes, payload records); Elixir supervisor running Julia worker processes; jobs and results as Arrow files with content hashes; a calibrated dummy model with tunable compute time, plus a real vanilla IRS valuation using FinanceModels. |
| 5-6 | Measurements: (a) dispatch overhead against payload size and worker count; (b) ledger completion rate with 8, 32 and 128 workers; (c) memo lookup latency with 10 and 100 million stored nodes; (d) worker start time with and without a system image; (e) identical result hashes across workers, restarts and thread counts; (f) Slurm: allocation to host serving, preemption, walltime drain, host loss. |
| 7 | Synthetic portfolio of 50,000 IRS through a dummy plan (valuation plus sensitivity nodes), at design size and at stress size where the laptop allows; per-node compute time of real IRS sensitivities. |
| 8 | Report: every target met or missed, with numbers and the decision each miss triggers. |

The spike's code is throw-away unless it already meets the specs; it does not
start the production build.

## 4. Decisions the results trigger

| Finding | Decision |
|---|---|
| Overhead above 20% of an IRS sensitivity node's compute | Block nodes: the planner groups positions of one book and perimeter sharing the same shocked objects; revisit D-039's one-node-per-position rule. |
| Ledger below 1,000 completions per second | Batch ledger writes per worker, partition node tables by as_of, or revisit XTDB (D-014). |
| Memo lookup above 2 ms at 100 million nodes | Partition by as_of and model; keep a hot calc_id index in Nebulex (the original accelerator idea). |
| Worker start above 30 s | Larger warm pools per host and longer allocations (D-037). |
| Result hashes differ anywhere | Stop: find the source of non-determinism before anything else (D-003, D-030). |
| Slurm host joins slower than 2 minutes | Request the EOD job array earlier (before cut-off) with a higher QOS (D-039). |
