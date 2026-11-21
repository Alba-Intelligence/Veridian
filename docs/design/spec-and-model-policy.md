# Allium specs and Quint models: how the two are used (D-055)

Allium (`specs/`) describes the whole system in domain terms. Quint
(`models/`) is an executable state-machine model, checked by simulation, of
the few protocols where ordering, retries and crashes decide correctness. They
are complementary, not alternatives. This document fixes who owns what.

## 1. When a protocol needs a model

A spec gets a Quint model when it defines a multi-party protocol in which
interleaving, retry or failure can break the result. Everything else stays
Allium only.

| Spec | Protocol | Model |
|---|---|---|
| 07 julia-workers | bundled dispatch, heartbeat loss, ledger commit per bundle | `bundled_dispatch.qnt` (D-055, D-056) |
| 02 calculation-graph | node completion and invalidation against the ledger | `calc_graph.qnt` (D-061) |
| 02e shared-layers | declared hub layers, one computation per hub, payloads fetched once per host, dependents on warm hosts | `hub_layers.qnt` (D-077) |
| 06 batch-scheduling | run cut-off, capacity request, resumption from the ledger | next (D-059) |
| 20 production-operations | recovery, release freeze window, interrupted-run resume | next with 06 (D-059) |
| 07 julia-workers, the rest | Slurm allocations, hosts joining, retiring, eviction, EOD array | next (D-059) |
| 05 configuration-release, 21 model-risk-management | four-eyes release gate, withdrawn validation | `release_gate.qnt` (D-057) |

The list is the intended scope, not a promise of order. A protocol is added by
a decision entry when its model is written. Linear workflows (succession,
restatement, review) are not modelled: a model checker finds little in them.

## 2. Authority

For the behaviour a model covers, **the Quint model is authoritative**. The
Allium spec describes that behaviour in domain terms and must stay
representative of the model: each construct of the spec that the model covers
carries a `-- model:` tag, and each model element carries the matching
`// spec:` tag (section 3). Allium remains the contract for everything the
models do not cover, and the only form in which reviewers who do not read
Quint see the protocol.

When the spec and the model disagree:
1. the disagreement is a finding, recorded as an `open question` in the
   spec and a note in `models/README.md`;
2. the user decides which is right; the loser is changed, and a decision entry
   records why;
3. while open, a model may carry both variants; the decision removes the
   loser. The loser may stay only as a labelled negative control (a `mutant`
   instance the gate requires to violate the property), as
   `dispatch_mutant_no_reap` does after D-056.

## 3. Correspondence (checked by `models/trace_check.sh`)

- In the spec, inside a `rule`, `invariant` or `@invariant`:
  `-- model: <model>.<element> [<model>.<element> ...]`
- In the model, on the comment lines directly before an `action`, `val` or
  `def`: `// spec: <spec>#<Construct> [, <spec>#<Construct> ...]` where
  `<spec>` is the spec file name without `.allium`.
- Every pair has to be stated on both sides. A tag on one side only fails the
  check. Constructs of a modelled spec that carry no tag are reported as a
  count ("11 of 56 traced") and are, by definition, not covered by a model.

The check compares names only. It does not prove that the prose of a rule
says what the model's action does; that is a review item whenever either
changes.

## 4. Gate

`devenv shell -- veridian-spec-check` runs `allium check` on all specs,
the traceability check, the regulation-tag check (`tools/reg-trace.sh --check`, D-084), and the model checks (`veridian-quint-check`). It must
pass before any commit that touches `specs/` or `models/`. A model check that
is expected to be violated (a recorded finding) and stops being violated also
fails the gate: the finding must be closed in the spec, the model and
the README together.

## 5. Limits, stated plainly

- The models are checked by random simulation (default 20000 runs per check),
  not exhaustively. Apalache is not packaged in nixpkgs; it was tried once
  by hand (`models/README.md`) and was too slow at the full instance, so
  `quint verify` is not part of the gate.
- A model covers a small instance (5 nodes, 2 workers, bundle size 2).
  Absence of a violation is evidence, not proof.
- A model is not the implementation. Nothing yet ties the Elixir control plane
  to the model; section 7 fixes how it will be tied (D-059).

## 6. Adding a protocol

1. Draft the Allium spec as usual and run `allium check`.
2. Write the Quint model: state, actions, a `safety` property, and a progress
   witness (a violated `notAllSettled`-style property).
3. Tag both sides (section 3); run `veridian-spec-check`.
4. Record the protocol and its model by a decision entry, and update the
   table in section 1.
5. Design the model so it can be replayed (section 7): actions take their
   non-determinism as arguments (`nondet` picks), and the state is plain data
   an adapter can project from the real system.

## 7. Conformance with the Elixir control plane (D-059)

Quint formalises the distribution and coordination the Elixir control plane
performs, so the code has to be shown to follow the model, not just resemble
it. Method: **trace replay in ExUnit**.

1. Quint writes traces: `quint run <model> --main=<instance> --n-traces=N
   --out-itf=<dir>/trace_{seq}.itf.json --mbt`. `--mbt` adds to each state the
   action taken and the values it picked. Traces of the system instance, and
   the violating traces of negative controls, are both kept as fixtures.
2. For each modelled protocol the control plane has one **adapter** module
   (test support, not production code). It starts the real components with
   fakes only for the outside world (workers, clock, ledger store), and maps
   each model action to the matching call or message.
3. An ExUnit test replays every step of a trace through the adapter and, after
   each step, compares the model's state with a projection of the real state
   (the model's variables are the contract of the projection). A difference is
   a finding, handled as in section 2.
4. Where replay finds drift, a StreamData state machine (D-049) may be added for
   that protocol; it is not the default.
5. Traces are regenerated by a devenv script and a fixed seed, committed only
   when the model changes, and the replay runs in the normal Elixir test run.
   Until the first control-plane code exists the adapters do not, and the gate
   of section 4 covers the models alone.

Limits: replay shows that the code can follow the traces simulated, not that it
follows every behaviour of the model; the implementation's own concurrency
(real scheduling, timeouts) is outside a replay and still needs its own tests.
