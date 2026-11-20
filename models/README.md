# Protocol models (Quint)

Rules for models and specs, authority and the traceability tags:
`docs/design/spec-and-model-policy.md` (D-055). The full gate is
`devenv shell -- veridian-spec-check`; `models/trace_check.sh` is its
traceability part.

`bundled_dispatch.qnt` models bundled dispatch of spec 07 (D-044, D-045):
tickets, workers, results in flight, heartbeat loss declaration (including a
false timeout), process death and one ledger transaction per bundle.

`hub_layers.qnt` models the shared layers of a plan (spec 02e, D-077): hubs
declared in layers, computed once, their payloads held once per host in a cache,
and dependents given only to hosts that already hold the hubs they need, in
bundles that need the same hubs. Instance `hubs` is the behaviour; each
`hubs_mutant_*` removes one control and the gate requires it to break the
property that guards it (`no_layers`, `every_host_computes`, `cold_hosts`,
`mixed_bundles`, `no_cache`). Size: 4 hubs in two layers, 6 positions, 2 hosts,
bundle of 2. Not modelled: which nodes are hubs, the fan-in fallback, payload
size, cache eviction, host loss (open questions in spec 02e).

Run with `devenv shell -- veridian-quint-check` (random simulation, offline;
`VERIDIAN_QUINT_RUNS` sets the runs per check, default 20000). The simulator
samples runs; it does not prove anything. Exhaustive checking (`quint verify`)
needs Apalache; see "Exhaustive checking with Apalache" below.

Size: 5 nodes, 2 workers, bundle size 2, 2 crashes per node, at most 2 faults
per run. Not modelled: priorities, builds, memo hits, time, backpressure, host
presence, recycling.

## Result (2026-11-17, 20000+ runs per check)

| Instance | `safety` | `noOrphanedReport` | all nodes settle |
|---|---|---|---|
| `dispatch` (the system, D-056) | holds | holds | reachable |
| `dispatch_mutant_no_reap` (negative control, not behaviour) | holds | **violated** | not checked |

`safety` is: a worker never holds more than the bundle size, a completed node
stays complete, a node is committed at most once, and an assigned ticket always
belongs to a worker not declared lost.

**Finding, resolved (D-056).** The first version of spec 07 said a worker's
death crashes only the tickets it still holds, while `BatchedLedgerWrite`
records a bundle's completions in one transaction after the last report. If the
host was declared lost between the first report and the commit (a real death,
or a false heartbeat timeout), the reported nodes were neither held nor
committed and stayed reported for ever. Shortest case found: bundle {0, 1};
node 1 reported; host declared lost before node 0 is reported.

Spec 07 now keeps a reported result on its ticket until the bundle commits, and
a lost worker's reported-but-uncommitted tickets are crashed like the held ones
(the graph retries; recomputation is cheap by memo, and a late result from the
lost worker is ignored). `dispatch_mutant_no_reap` is the old behaviour kept as
a negative control: the gate requires it to violate `noOrphanedReport`.

## Exhaustive checking with Apalache (investigated 2026-11-17)

- **Packaging.** nixpkgs has no Apalache package. The repository's `flake.nix`
  (github:apalache-mc/apalache) exposes only a development shell for building
  Apalache (`devShell` and `packages.<system>.dev-shell`), not an Apalache
  package. The project publishes a prebuilt `apalache-<version>.tgz` (a JVM
  application, about 190 MB) and a `sha256sum.txt` on each release.
- **How Quint uses it.** Quint 0.33.1 wants Apalache 0.62.4. If
  `$QUINT_HOME/apalache-dist-0.62.4/apalache/bin/apalache-mc` is missing it
  downloads and unpacks the release itself, with no hash check; `QUINT_HOME`
  defaults to `~/.quint`. A JDK 17 or later is needed (nixpkgs `jdk17_headless`
  works).
- **A reproducible install, if wanted.** Fetch the release with Nix `fetchurl`
  pinned to the hash (0.62.4 `.tgz`:
  `b781b53bba32fac14ac2e02b0332e1dc2edc64cb7b850c0608d8142cc7aa2ef4`, equal to
  the value in the release's `sha256sum.txt`; both come from the same host, so
  this checks integrity, not authenticity), unpack it into a project directory
  laid out as above, and set `QUINT_HOME` to it in devenv. Not done: nothing
  is added to `devenv.nix` or the gate.
- **Tried once, in a scratch `QUINT_HOME` (measured with Syncthing running).**
  `quint verify models/bundled_dispatch.qnt --main=dispatch --invariant=safety
  --max-steps=10` works, but the cost grows with depth: after about 13 minutes
  it had checked states 0 to 7 and was part way through state 8, and each
  state took longer than the one before (seconds at first, minutes at state 8).
  It was stopped at that point. A complete run of this model needs 16 or more
  steps, so exhaustive checking of this size at useful depth is not practical.
- **What would make it practical.** A smaller instance for `verify` only (for
  example 3 nodes and one worker), bounded depth, and keeping the 5-node
  instance for simulation. Not tried. Until then the models are checked by
  simulation, as stated in the policy.

## `release_gate.qnt`: the production release gate (specs 05, 21)

Models releases that are submitted and then evaluated at a separate step,
validations that expire, are withdrawn or replaced, benchmark breaches, one
active release replaced atomically, and the independence rules (release
author and reviewers, validator and model owner or first author, breach
reviewer and owner). Two releases, two models, four users; each release names
the model versions it adds or changes, and the gate looks at those only (D-058).

Result (20000+ runs per check, random simulation):

| Check | Expected | Result |
|---|---|---|
| `safety` (one active release, reviewed releases, gate held at activation, validator and reviewer independence, no gate refusal without a change) | holds | holds |
| `gate_mutant_no_gate` against `gateHeldAtActivation` | violated | violated |
| `gate_mutant_no_supersede` against `oneActive` | violated | violated |
| `gate_mutant_no_review` against `reviewedProduction` | violated | violated |
| `gate_mutant_all_models` (the gate as before D-058) against `noGateRefusalWithoutChange` | violated | violated |
| witness `notActivated` | violated | violated (a release can be activated) |
| witness `notRefusedByGateAlone` | violated | violated (a release that changes a model can be refused by the gate alone) |

The safety properties follow from the guards in the actions, so they hold
largely by construction; the model's main value here is that it fixes the
semantics (evaluation is atomic and replaces the previous active release in one
step, which is a requirement on the Elixir implementation: check and
activation in one transaction) and that the mutants show each property would
notice the control going missing.

**Design consequence found, then decided (D-058).** With the first version of
the gate, every release carried every model version, so a validation that was
expired, withdrawn or had an open breach blocked every new production release,
including one that changes nothing about models, such as a calendar fix; with
no overrides (NoOverrides) nobody could release it. The user chose to gate only
the model versions a release adds or changes. `gate_mutant_all_models` keeps the
old behaviour as a negative control.

## `calc_graph.qnt`: the calculation graph against its ledger (spec 02)

Models three requests with two evaluation steps each. Step A depends on the
request's input; step B on A's result. A node's calc_id is its identity: A from
its input, B from A's result hash (early cutoff). Two inputs give the same A
result, so their B steps meet in one node. Covered: binding a ready step (new
node, memo hit, attach to an in-flight node, purged payload, failed node),
dispatch, success, crash and retry, rejection, payload ageing and
rematerialisation, ringfenced step failure, cancellation. Not covered: planning
and expansion, bitemporal resolution, data classes, queue capacity, wall-clock
time (a timeout is a crash, ageing is nondeterministic), the worker protocol
(see `bundled_dispatch.qnt`). Every action is one atomic ledger step: the unique
calc_id and the conditional state change happen in one transaction, a
requirement on the Elixir implementation.

Instances: `calc_graph_fixed` is the behaviour (D-062). The
`calc_graph_mutant_*` instances are negative controls: `no_stampede`, and
`dup_remat` and `remat_broken`, which are spec 02 as it was written before
D-062 (the two findings below).

| Check | Expected | Result |
|---|---|---|
| `safety` on `calc_graph_fixed` (attempts bounded, one node per calc_id, one computation in flight, one recomputation in flight, no recomputation of an irreproducible node, done steps sound, ringfence, request states agree) | holds | holds (20000 runs) |
| `calc_graph_mutant_no_stampede` against `oneInFlight` | violated | violated |
| witnesses (unfulfilled request, memo hit, attach to a computing node, rematerialisation, retry then success, failed node) | violated | violated |
| the five scenarios on `calc_graph_fixed` | pass | pass |
| `purgedTwiceTest` on `calc_graph_mutant_dup_remat` | fails | fails |
| `brokenNodeTest` on `calc_graph_mutant_remat_broken` | fails | fails |

Random simulation does not reach the deeper sequences (about 20 specific steps:
a fulfilled request, shared B node, a purged shared node), so those are replayed
by scenarios (`quint test`), not found by chance.

**Findings, adopted by the user (D-062)**; the spec and the model are changed,
the old behaviour stays as the two mutants above:

1. *Stampede control for a purged payload is not enforced.* Every step binding
   to a purged payload raises a recomputation, and the dispatch rule only checks
   that the payload is purged: n waiting steps dispatch n recomputations
   (`purgedTwiceTest`: 2 against 1). The spec text says one.
2. *An irreproducible node still triggers recomputations.* A step binding to a
   node already marked irreproducible is set running and a recomputation is
   dispatched, though the node can no longer serve results
   (`brokenNodeTest`). The step is now abandoned at binding.

**Gap left by adopting finding 1, not yet modelled:** with a single in-flight
recomputation flag, a recomputation that is lost (worker crash, timeout) would
leave the waiting steps waiting for ever. A lost recomputation must clear the
flag and be retried up to `max_attempts`, then fail the waiting steps. Recorded
as a spec 02 open question; the model has no action for it yet.
