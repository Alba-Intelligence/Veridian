# Local measurements before production code

Status: plan, 2026-11-19. The user chose to run all remaining spike measurements
on the development laptop (8 cores, 31 GB RAM, about 8 GB free, slow disk: a
durable Postgres commit costs about 183 ms and the disk shows I/O stall even when
idle). Source of the open items: `spike-report.md` section 2 ("not measured").

Rule for reading every result here: it is a measurement of this laptop. It bounds
the design from one side (a worst case for storage, a best case for CPU) and does
not replace a run on production-class hardware. Each result is recorded with that
label, and a decision is only triggered when the bound is on the wrong side.

| # | Target not yet measured | What can be measured here | What it can and cannot show |
|---|---|---|---|
| M1 | Memo lookup under 2 ms p99 at 100 M nodes | 100 M rows in one table (about 25 GB, index larger than RAM), cold and warm; and the same rows split into daily partitions by `as_of`, looking up inside one partition (about 2.3 M rows, index in cache) | One table: worst case, disk-bound, expected to miss. Partitioned: tests whether the D-043 fallback (partition by as_of and model) meets the target when the working set fits the cache. It cannot show production storage behaviour |
| M2 | EOD at stress in 2 h on grid hosts | The bundled-dispatch prototype over 2.3 M nodes on 8 cores, per-position nodes, 5% recomputed | Throughput of the control plane and ledger on 8 cores with the spike's model cost; the real model cost and the grid's host count are not measured. Result is a rate to extrapolate from, with the extrapolation shown |
| M3 | 50 traders and 10 reviewers at once; desk view 1,000 swaps under 5 s | Synthetic ledger read load of that shape against the M1 database, plus the existing 1,000-swap valuation node (0.5 ms) | Database and node side only. There is no desk view code, so the 5 s figure is a lower bound without rendering |
| M4 | Storage growth: 1.2 M ledger rows and 5 GB of payloads per day | Bytes per row in `nodes`, `payload_records`, `events` and the payload files from the M2 run, and the table and index sizes after M1 | Gives real per-row sizes to multiply; the daily row and payload counts remain D-043 assumptions |

Order: M4 sizes come out of M1 and M2, so M1, then M2, then M3 and M4 from their
databases. Each starts only after the previous one is finished and its result is
written down.

Environment rules:
- Runtime state stays outside the synced tree, in a local state directory, so the file-sync tool does not scan the
  data and distort I/O. Pause it for the run if it is still scanning.
- Record the commit mode (`synchronous_commit`) and whether the page cache was cold, with every number.
- The user's session shares the machine: long runs are started at low priority (`nice`, `ionice -c3`), and the
  load seen by the user is the reason to stop a run early.

Stop conditions: disk below 40 GB free, memory pressure from the run affecting the
desktop, or a run past twice its estimate. Report and ask before continuing.

Results go to `spike-report.md` section 2 (replacing "not measured") and decisions
are proposed from section 3, not taken here.

## M1 result (2026-11-19): memo lookup at 100 M nodes

Laptop, Postgres 18.7, `fsync=off`, `synchronous_commit=off`, `shared_buffers=2GB`,
about 8 GB of RAM free for the page cache, 1 or 16 pgbench clients, random existing
`calc_id` (sha256 key), `SELECT result_hash`. The raw log and the harness script are prototype
material and are not published.

Size at 100 M rows: table 13 GB, primary-key index 5.6 GB (18.6 GB; about 190 bytes per node).

| Case | Readers | p50 | p99 | Against p99 < 2 ms |
|---|---|---|---|---|
| 100 M table, cold (3,000 lookups) | 1 | 175 ms | 1,191 ms | **Missed** |
| 100 M table, continued random (300 s, 2,091 lookups) | 1 | 110 ms | 722 ms | **Missed** |
| 100 M table, continued random (180 s) | 16 | 137 ms | 1,596 ms | **Missed** |
| 2.3 M partition-sized table, warm (60 s, 578 k lookups) | 1 | 0.08 ms | 0.25 ms | **Met** |
| 2.3 M partition-sized table, warm (60 s, 3.35 M lookups) | 16 | 0.27 ms | 0.73 ms (p99.9 2.4 ms) | **Met** |

What this shows:
- One table of 100 M nodes does not meet the target on this machine. The index (5.6 GB)
  plus the hot heap does not stay in the cache here and every miss is a random disk read at
  about 100 ms. This is a bound set by this disk and 8 GB of RAM, not a property of Postgres.
- The same lookups on a table the size of one daily partition (2.3 M rows, 440 MB with its
  index) meet the target with wide margin, even with 16 readers, once the cache is warm. A
  lookup that names its `as_of` partition reaches only that partition's index. So the D-043
  fallback (partition by `as_of`, and by model) is supported in principle.
- Not shown: how long a partition takes to warm after a restart (the cold partition run
  gave p50 91 ms, p99 1.4 s for the first 3,000 lookups, so a warm-up step is needed), and
  whether a lookup that does not know the `as_of` must visit every partition. The memo key
  is the content hash, which does not contain `as_of`, so the partition rule needs a design
  decision before it can be relied on.

Decision input for D-043 section 4 (partition and hot index): keep "partition by `as_of`
and model" as the proposal, and settle first how a lookup finds its partition. Production
storage can be expected to do better than this disk; it is not measured here.

## M2 and M4 results (2026-11-20): end-of-day plan throughput and ledger size

Laptop, 8 Julia workers, bundled dispatch (100 nodes per bundle), one node per
position and kind (valuation, entity sensitivity, group sensitivity), Postgres 18.7
with asynchronous commits unless stated. The harness is prototype
material and is not published. The stress-size plan (766,667 positions, 2.3 M nodes) was **not**
run in one piece: result files in RAM would not fit (about 9 GB), and on disk each
result file costs about 110 ms here.

| Run | Nodes | Priority | Inputs | Fresh run | Memoized rerun |
|---|---|---|---|---|---|
| 5,000 positions (rehearsal) | 15 k | default | disk, warm cache | 4,498 nodes/s | 9,175 nodes/s |
| 20,000 positions | 60 k | nice 17 | disk | 531 nodes/s (113 s) | 8,294 nodes/s |
| 20,000 positions | 60 k | normal | disk | 2,787 nodes/s (21.5 s) | 8,541 nodes/s |
| Half of stress (383,334 positions) | 1.15 M | nice 17 | disk | 1,244 nodes/s (925 s) | 5,357 nodes/s |
| 100,000 positions | 300 k | normal | RAM | 2,227 nodes/s (135 s) | 3,594 nodes/s |
| 100,000 positions, Postgres also normal | 300 k | normal | RAM | 2,601 nodes/s (115 s) | 3,963 nodes/s |
| 100,000 positions, durable commits | 300 k | normal | RAM | **not measured** (see below) | |

What this shows:
- **The control plane is not CPU-bound.** Sampling per-process CPU, the BEAM, the Julia
  workers and Postgres together used about 0.5 of 8 cores at low priority and about
  2 to 4 cores in bursts at normal priority. Worker compute per node is 0.2 to 0.4 ms;
  the median overhead per node is 2.5 to 3 ms (1.4 ms in the 15 k rehearsal).
- **Priority matters more than the design here.** The same 60 k-node run is 5.2 times
  slower at `nice -n 17` than at normal priority, with the cores 70% idle. Results at
  nice 17 measure the scheduler on a busy desktop, not the system.
- **Input reads from disk were an artefact of the harness.** Cold position files cost
  6 to 15 ms each on this btrfs disk (one tiny file per position, read in an order that
  scatters across the disk). Production reads positions from tables or object storage.
  The 100 k runs put inputs and results in RAM to remove this.
- **Open, not explained:** the fresh rate (2.2 to 2.6 k nodes/s) is below the spike's
  4.4 to 4.9 k nodes/s on 150 k nodes, and the memoized rerun slows as the ledger grows
  (8.3 k nodes/s at 60 k nodes, 4.0 k at 300 k). Both may be the busy machine (about
  20 GB of swap in use by the desktop); neither is verified.
- **Extrapolation, labelled as such:** at 2.2 to 2.6 k nodes/s the 2.3 M-node stress plan
  would take 15 to 17 minutes; at the half-size nice-17 rate (1.2 k) about 31 minutes.
  The target is 2 hours on grid hosts. This is not a result for grid hardware.
- **Durable commits not measured.** Two attempts failed: first on the database pool's
  15 s query timeout, then on its overload shedding (`timed out because it queued`,
  default 50 ms queue target), both raised in `application.ex`; a third attempt ended
  when the session itself crashed, probably from memory pressure (workers took 35 to
  42 s to start instead of 3 to 14 s). The spike's earlier durable figure (1,280 nodes/s
  on 150 k nodes, bundles of 100) stands as the only durable number.

### M4: storage per node

From the ledger tables after the runs (nodes, payload records and events, with their indexes):

| Run | Nodes | nodes table | payload_records | events | Per node |
|---|---|---|---|---|---|
| 100 k positions | 300 k | 62 MB | 90 MB | 36 MB | 627 bytes |
| half of stress | 1.15 M | 239 MB | 345 MB | 136 MB | 626 bytes |

Result payload files in these runs are about 3.9 KB each (4 KB block): the spike's
payload is one small Arrow file per node, so this is a floor, not a real payload size.

Scaling by those numbers: the design plan (about 235 k nodes per day) is about 150 MB
of ledger and 0.9 GB of payload files; the stress plan (2.3 M nodes) about 1.4 GB of
ledger and 9 GB of payload files. D-043 assumed 1.2 M ledger rows and 5 GB of payloads
a day; the ledger here is three rows per node (about 700 k rows for 235 k nodes) and
well under that in bytes. Real payloads (sensitivity vectors, curves) will be larger
than the spike's, so the payload figure needs the real models before it means anything.

### Decision input

- Bundled dispatch (D-044) holds up: memoization stays per position, and the control
  plane does not look like the limit on this machine.
- Nothing measured here reopens D-039 or D-044.
- The durable-commit rate at stress size, the memo-lookup partition rule (M1) and real
  payload sizes remain open and need production-class hardware or the real models.

## Ledger through Ash (2026-11-20, D-073)

The first production-code ledger (an Elixir application, PostgreSQL through the Ash
framework) was measured on the same laptop with a throwaway cluster:
`fsync` off, asynchronous commit, normal priority, 4,000 positions (12,000 rows in
all). It measures the Elixir and Postgres CPU path. It is **not** durable commits
and **not** 100 M rows.

| Operation | One caller | 8 callers at once |
|---|---|---|
| Commit a bundle of 100 completions (one transaction) | 1,200 nodes/s | 5,800 nodes/s |
| Bind a step that creates its node | 350/s | 1,600/s |
| Bind a step to an existing complete node (memo hit) | 450/s | 2,000/s |
| Submit one request with many steps (row by row) | 3,000 steps/s | |
| Lookup by calc_id (one read) | p50 0.5 ms, p99 1.0 ms | |
| **Whole path per node**: one request of 4,000 steps; 8 workers each bind, dispatch, commit a bundle of 100, finish the steps | | **700 nodes/s** |
| Whole path per node with bundle calls (bind, dispatch, commit, finish, each one transaction per bundle of 100; D-074) | | **800 nodes/s** |
| Submit one request of 4,000 steps, bulk insert (was 3,000/s row by row) | 22,000 steps/s | |
| Whole path for memo hits (bind only) | | 2,000 nodes/s (one request, 8 workers, per-node bind) |

**The whole path is below the ledger target of 1,000 nodes/s** (700 with one
transaction per node, 800 with bundle calls: the cost is about 25 statements per
node through the framework, not the transactions; at 800 nodes/s a 2.3 M-node plan
needs about 48 minutes of ledger time here). Each operation
looks fast alone, but a node costs several transactions: bind, dispatch and
finishing its step are one transaction per node here, whereas only the commit is
per bundle. The design (D-044) amortises dispatch and completion per bundle; the
next step is to apply that to the rest of the path and measure again. These
numbers are not comparable with the spike's whole-path figures, which skipped the
framework and the row locks.

### Update: bundle engine (2026-11-20, D-078)

The ledger's bundle calls now read, lock and write each table once per bundle
(constant statements per bundle) instead of per node. Same laptop, same setup
(throwaway cluster, `fsync` off, asynchronous commit, 8 workers, bundles of 100):

| Operation | 4,000 nodes | 20,000 nodes |
|---|---|---|
| **Whole path per node with bundle calls** (bind, dispatch, commit, finish) | **10,800 nodes/s** | **12,000 nodes/s** |
| Memo hits through the bundle bind | | 13,000 nodes/s |
| Commit a bundle of 100 completions, one committer | 18,000 nodes/s | |
| Per-node calls (unchanged, for comparison) | 600 to 800 nodes/s | 630 nodes/s |

These are with asynchronous commits (`fsync` off). The target of 1,000 nodes/s is
judged on durable commits (D-044), measured on the same disk with `fsync`,
synchronous commit and full-page writes on:

| Bundle size | Whole path per node, durable | Memo hits through the bundle bind, durable |
|---|---|---|
| 100 | 1,200 to 1,400 nodes/s | 5,600 nodes/s |
| 500 | 5,200 nodes/s | 14,900 nodes/s |

Each bundle takes four commits (bind, dispatch, complete, finish) and the path is
bound by commits, about 45 to 55 per second on this laptop disk. So the target is
met durably, **narrowly at bundles of 100 and comfortably at 500**; production
storage will change the commit rate. Not 100 M rows, not contended by other
writers. Callers must use the bundle calls: per-node calls keep their old cost.

### Ash bulk upsert against raw SQL (2026-11-20, D-079)

The figures above used a raw-SQL write-back. The ledger now writes through Ash's
bulk upsert instead. The machine was busy with other heavy work, so the two were
compared on figures that do not depend on wall time (`veridian-ledger-cost`:
exact counts, and CPU time of the BEAM and of the database processes; 4,000
nodes, bundles of 100, 4 workers, one run each):

| Per bundle / per node | Raw SQL | Ash bulk upsert |
|---|---|---|
| Statements per bundle | 23 | 23 |
| Commits per bundle | 4 | 4 |
| Database CPU per node | 150 µs | 155 µs |
| BEAM CPU per node | 370 µs | 700 µs |

Where commits are the limit (durable commits) the two are the same. Where CPU is
the limit, Ash costs about 330 µs more per node, still more than 1,000 nodes/s on
one core. The counts are exact; the CPU times are indicative.
