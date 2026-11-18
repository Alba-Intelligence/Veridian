# Laptop spike report (D-043)

Status: results of the 8-day spike, 2026-11-13 to 2026-11-14. Details, tables and
commands are in `spike/README.md`; the code is in `spike/` (throw-away, D-043).
Option B of section 4 was accepted on 2026-11-15 as D-044 (spec 07 amended),
together with batched ledger writes. The host heartbeat and the EOD array
requested before the cut-off (section 5) were accepted the same day as D-045
(specs 06 and 07 amended). Still open: the 100-million-node memo lookup.

## 1. Conditions that shape every number

- Laptop: 8 cores, 31 GB RAM, **slow disk**: a durable Postgres commit costs
  about 181 ms (1-2 ms with `synchronous_commit=off`) and I/O pressure is about
  90% even when idle. Disk health is unchecked (`smartctl` is blocked).
- **Syncthing was running** during all measurements (it scans the synced tree).
- Page cache warm unless stated; single-threaded model code; simulated Slurm
  (one controller, three slurmd on one host, no cgroups, no accounting).
- Result files were written to RAM in day 7 (on this disk they cost 100-300 ms).
- Numbers from this laptop bound production from neither side: slow storage
  makes durable-commit and file-write numbers pessimistic, a warm cache and a
  light model make compute and lookup numbers optimistic.

## 2. Targets: met, missed or not measured

| Target (D-043 section 1) | Result | Verdict |
|---|---|---|
| Ledger: 1,000 node completions per second | async commit: 5.7-6.8k/s (8, 32, 128 writers), 8.6k/s batched; durable commit on this disk: 19-165/s one per transaction, 2.2k/s at 25 per transaction | **Met** async; durable **met only by batching** |
| Memo lookup under 2 ms p99 at 100 M nodes | 10 M nodes, warm: p50 0.36 ms, p99 0.94 ms (1 reader), p99 3.9 ms (16 readers); cold: p50 91 ms, p99 603 ms. 100 M not measured (index would not fit the cache) | **Not measured**; 16 readers and cold cache miss |
| Dispatch overhead under 5 ms median, 20 ms p99 | trivial jobs, 8 KB payload: p50 1.8-3.0 ms, p99 3-6.6 ms; from 0.8 MB: 27 ms and up (disk bound). Real IRS jobs (day 7): p50 4.8-5.5 ms, p99 13-17 ms at 100 swaps per node, 135-155 ms at one swap per node (150,000 nodes, disk stalls) | **Met** at design payload; median borderline and p99 **missed** under sustained load |
| Worker ready under 30 s; first job under 1 s extra | system image: ready 1.6-1.9 s (2.3-9.4 s with 8 starting at once), first job 0.57-0.65 s; without image 8.4-9.3 s and 8.8-11 s | **Met** with a system image only for the first-job part |
| Grid allocation to host serving under 2 min | 0.5-1.0 s (simulated Slurm) | **Met** |
| EOD at stress in 2 h on grid hosts | not run; 2.3 M nodes at the measured 600-800 nodes/s is about 60 min on 8 laptop cores, before real model cost | **Not measured** (extrapolation only) |
| Desk view of 1,000 swaps under 5 s; what-if under 2 s | not in the spike's scope; a 1,000-swap valuation node computes in 0.5 ms | **Not measured** |
| 50 traders, 10 reviewers concurrently | not measured | **Not measured** |
| Storage growth (1.2 M ledger rows, 5 GB payloads per day) | not measured | **Not measured** |
| Identical result hashes (section 4, D-003, D-030) | 24 results per kind across 1, 2, 4, 8 threads, restart and system image: one hash each | **Met**, but the model is single-threaded: no parallel reduction was exercised |

## 3. Decisions the results trigger (D-043 section 4)

| Finding | Triggered decision | Proposed |
|---|---|---|
| Overhead above 20% of an IRS sensitivity node's compute: **yes**, at every block size (381% at one swap per node, 73% at 1,000). Overhead floors at about 4.5-7 ms | Block nodes, revisit D-039's one node per position | See 4: block nodes alone are not enough |
| Ledger below 1,000/s | Batch ledger writes per worker | **Yes**: write completions in batches (25 or more per transaction). Needed on slow storage and wanted anyway for bundled dispatch. XTDB (D-014) needs no revisit: Postgres cleared the target |
| Memo lookup above 2 ms at 100 M | Partition by as_of and model, hot calc_id index | **Hold**: 100 M unmeasured. Evidence leans to the hot index (p99 3.9 ms with 16 readers at 10 M). Measure on production-class storage before deciding |
| Worker start above 30 s | none | Ship the system image (546 MB) with every worker build; first-job target needs it |
| Result hashes differ | none | none; repeat with a threaded reduction once a model uses threads |
| Slurm host slower than 2 min | none | Still request the EOD array **before cut-off** (below). Accepted as D-045 |

## 4. The main finding: node granularity (reopens D-039)

Per swap, a vanilla IRS sensitivity costs about 10 us of compute once the
shocked curves are shared (1,000 swaps: 10 ms; the 1.25 ms at one swap is the 18
curve refits). D-043 assumed a few ms per node, so the planned work per node is
about 100 times smaller than assumed, against 4.5-7 ms of dispatch overhead per
node. One node per position is therefore far too fine for dispatch.

But large blocks break memoization: with 5% of trades changing daily, a 100-swap
block is recomputed about 99% of the time, a 10-swap block 40%, a single
position 5%. Two options, neither tested:

- **A. Block nodes that reuse per-position results**: the payload keeps one
  result per position keyed by its input hash; a changed block recomputes only
  the changed positions. Keeps few nodes and few ledger rows; makes the node's
  payload a small content-addressed store of its own.
- **B. Per-position nodes dispatched in bundles**: the graph and memo stay at
  position level; a worker takes many nodes in one round trip and the ledger
  records them in one transaction (batching already gave 10x). Keeps the
  D-039 graph and early cut-off exactly; costs 235,000 ledger rows per EOD, as
  planned.

Recommendation: prototype B first. It leaves specs 02, 07 and 11 untouched
(nodes stay as specified) and changes only how the control plane dispatches.
A changes what a node is, which touches the memoization semantics (D-003).

**Result of prototyping B** (branch `worktree-bundled-dispatch`, `spike/README.md`
"Day 7b"): at one node per position, 150,000 nodes, with a per-process cache of
shared shocked curves and bundles of 25-400 nodes per worker round trip, the plan
runs at 4.4-4.9k nodes/s against 642 on day 7 (31 s against 234 s), amortised
overhead 1.3 ms, and a 5% change recomputes 5% of the nodes. With durable commits
and bundles of 100 it still runs at 1,280 nodes/s, above the 1,000/s ledger
target. The stress plan extrapolates to about 8 minutes async or 30 minutes
durable on this laptop. B is therefore a workable answer: keep one memoizable
node per position (D-039 stands) and dispatch in bundles. Not shown: behaviour
when a worker dies mid-bundle, heavier models, stress size, and on production-class
storage. **Accepted as D-044 (2026-11-15):** B is the working assumption for the
build, bundle size is a configuration value (starting at 50; the spike saw the
same throughput from 25 to 400), and A is dropped unless a model is found whose
nodes cannot be reused per position.

## 5. Slurm findings the control plane must respect (D-037, D-045)

Accepted as D-045: the host heartbeat drives recovery (specs 07), the EOD array
is requested `capacity_lead` before the cut-off (specs 06 and 07) and hosts stop
on the first signal. The findings behind it:

- Preemption by partition priority works but Slurm acted 11-34 s after the
  request (its scheduling pass; state saves are slow on this disk) and did not
  hold the preemptor for the victim's `GraceTime`: the new host started while
  the old one was still draining. Treat SIGTERM as immediate eviction and
  request the EOD array before cut-off (D-039).
- Walltime warning (`--signal=B:USR1@30`) arrived about 45 s before the limit,
  not 30 s; drain works and the job ends cleanly. Do not depend on the lead
  time.
- Host loss: the node is `idle*` within seconds but DOWN only after about a
  minute despite `SlurmdTimeout=10`. A frozen host was noticed by a 5 s
  heartbeat monitor in 4.7 s and by Slurm's job state after 47-49 s. The
  control plane's own heartbeat must drive recovery.
- When only the agent process dies, the job ends and Slurm notices in 25 ms.

## 6. Not done, and what would close it

- 100 M-node lookup, durable-commit and file-write numbers: re-run on
  production-class storage (set `postgres.dataDir` in `spike/config.nix`).
- Stress size: needs real bank hardware, or a longer unattended run.
- Heavier models (bonds, callables, equity options): the IRS pricer is the
  lightest case; dispatch economics improve with heavier nodes.
- Shocked curves as separate nodes consumed by sensitivity nodes (refits are
  inside each node in the spike).
- Desk view, what-if latency and concurrency belong to a later spike with the
  front end.
- A threaded-reduction determinism check, once a model uses threads.
- Re-run with Syncthing paused (or `.stignore` for the worktree and `spike/data`)
  to separate its effect; the owner has not decided on a `.stignore`.
