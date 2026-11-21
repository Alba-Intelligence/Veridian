# Veridian

**Regulation, formalized. Computation, verified.**

Veridian is a platform design, with a first slice of code, for computing a
bank's market-risk regulatory figures so that every number can be **reproduced,
explained and traced**: back to its inputs, to the code and environment that
produced it, and to the part of the regulation it answers to.

This repository holds the specifications and executable protocol models that
define it, the code built against them so far, and the tools that keep the
three consistent.

## Why

A regulatory figure (a capital charge, a sensitivity, a report cell) is the end
of a long computation over market data, trades and reference data, run by code
of a particular version in a particular environment. Supervisors, validators
and auditors ask why it is what it is, and they ask again two years later.
Most platforms answer by convention: careful people, logs, a wiki. Veridian
tries to answer by construction:

- **The same inputs, code and environment give the same result**, and a result
  is never silently replaced. Every figure is a node in one calculation graph,
  identified by a hash of what it depends on (model version, as-of date, the
  content hashes of its inputs, the results of its prerequisites), recorded in a
  ledger. An identical request is answered from the ledger, not recomputed.
- **Time is explicit.** Inputs are bitemporal: what was true on a date and what
  was known when. A figure can be restated or reproduced as of any past moment.
- **Control is part of the system.** Identity and rights, a hash-chained audit
  log, four-eyes release control and independent model validation are specified
  alongside the calculations.
- **The design is checkable, not just written down.** Behaviour is specified in a
  language reviewers can read, the protocols that can fail are modelled and
  simulated, and the code is replayed against the models.
- **A rule can be followed from the regulation to the test** that checks it, and
  where the chain stops, the tools say so.

None of this makes a figure compliant. Compliance belongs to the bank; Veridian
supplies evidence that can be inspected.

## How it is built, and why

| Layer | What | Why this choice | How far it is checked |
|---|---|---|---|
| Calculation graph and ledger | content-addressed, immutable nodes; memoization; early cutoff when a prerequisite's result is unchanged | reproducibility and explanation by construction | specification, model, replayed tests |
| Control plane (Veridian Fabric), Elixir | ledger, scheduling, supervision of workers, release control, audit | built for supervised, failing processes; a worker crash cannot corrupt the ledger | tests, types, Dialyzer |
| Compute plane (Veridian Core), Julia | pricing and risk models, calendars, canonical form and hashing | numerics and the JuliaActuary ecosystem; stateless workers | tests, frozen vectors from an independent implementation |
| Specifications in Allium (`specs/`) | behaviour in domain terms: rules, invariants, surfaces | readable by people who do not read code | `allium check`, human review |
| Protocol models in [Quint](https://quint-lang.org) (`models/`) | the few protocols where ordering, retries or crashes decide correctness | find what review misses | random simulation on small instances |
| Reproducible environment (Nix, devenv) | checkers, compilers and databases declared and pinned | the same checks run the same way for everyone | declarative and rebuildable; not a proof |

Specifications and models are tied together: a rule that a model covers
carries a `-- model:` tag, the model element carries a `// spec:` tag, and the
check fails if either side is missing. For what a model covers, the model is
authoritative and the spec describes it
(`docs/design/spec-and-model-policy.md`).

Each layer is cheap where it is strong, and each is used where the one above
cannot see. A spec can be wrong in ways only a model or a reading of the
regulation reveals; a model can be right while code drifts from it; code can
pass tests written by someone who misread the rule. The bugs found so far came
from different layers. Both the specs and the models were drafted with an LLM
coding agent and then checked mechanically; getting from an informal idea to a
precise specification is the effort that used to make this approach rare.

## What the models found

- **Stranded results (spec 07, `models/bundled_dispatch.qnt`).** Workers report
  results one by one, but the ledger commits a bundle in a single transaction at
  the end. If a host was declared lost between the first report and the commit,
  the reported results belonged to nobody and were never recomputed. Shortest
  case: a bundle of two nodes, one report, one lost host. The spec now keeps a
  reported result on its ticket until the bundle commits.
- **Recomputation stampede (spec 02, `models/calc_graph.qnt`).** The spec said
  one recomputation per purged result; with n steps waiting, the model showed n.
  A step bound to a node already marked irreproducible also triggered a
  recomputation. Both are fixed.
- **Release gate (specs 05 and 21, `models/release_gate.qnt`).** One lapsed
  validation blocked every new release, even one that changed no model. Decided:
  the gate looks only at the model versions a release adds or changes.
- **Shared layers (spec 02e, `models/hub_layers.qnt`).** Very many instruments
  share a few inputs (one swap curve, its discount factors and bumped curves).
  The model checks the design that computes such declared hubs once, layer by
  layer, sends each payload to a host once, and gives dependents only to hosts
  that already hold their hubs; five mutants, one per control, are each caught.

The old behaviour stays in each model as a *negative control* (a `mutant`
instance), and the gate requires the checks to still catch it.

## From regulation to test

A rule in a spec can cite the part of a regulation it implements:

```
-- reg: BCBS239.P3
-- reg: MAR21.19-24
```

`tools/reg-trace.sh <id>` joins those tags with the spec-to-model tags and with
the tests that replay or name each model, and prints the chain with what each
link is worth (reviewed by people, random simulation, replay of sampled traces,
direct test). Where the chain ends it says so, for example a paragraph whose
specification has no model and no test yet. The tool cites and links the
regulations; it never quotes them. It checks that what is tagged exists; it
cannot check that a spec says what the regulation says or that a test bears on
the rule. Those are review steps.

```
tools/reg-trace.sh BCBS239.P3      # follow one identifier
tools/reg-trace.sh --list          # every identifier some spec cites
tools/reg-trace.sh --check         # fail if a tag names something missing
```

Coverage is thin so far: one principle of BCBS 239 and the MAR21 sensitivity
definitions are traced. A web front end over these relations is planned as a
read model; the tags in the repository stay authoritative.

## Reading path

1. `specs/04-identity-access-audit.allium`: identity, rights, hash-chained audit.
2. `specs/05-configuration-release.allium` and
   `specs/21-model-risk-management.allium`: release control and model validation.
3. `specs/02-calculation-graph.allium`: the memoization ledger.
4. `specs/07-julia-workers.allium`: workers, bundles, host supply.
5. `specs/11-frtb-sa.allium` and `specs/22-simplified-standardised-approach.allium`:
   regulatory calculations.
6. `models/README.md`: what each model covers and what it does not.
7. `docs/design/decisions.md`: the decision log, with the reasoning.

Large specs are split into parts that sit beside the main file and share its
number: `02-calculation-graph.allium` is continued in `02b-node-execution`,
`02c-payload-retention`, `02d-attempts-and-inspection` and `02e-shared-layers`,
and likewise for 01, 04, 06, 07, 10, 13, 19, 20, 21, 25 and 26. Read the main
file first.

## Run the checks

```
devenv shell -- veridian-spec-check
```

This runs `allium check` on all specs, the two-way spec and model traceability
check, the regulation-tag check, and the model checks (random simulation, 20000
runs per check by default; `VERIDIAN_QUINT_RUNS` changes it). Needs
[devenv](https://devenv.sh) (Nix). All specs are checked together: a single spec
alone gives spurious unresolved-reference warnings.

## The code

| Path | What it is | Check |
|---|---|---|
| `julia/VeridianCanonical/` | The canonical form of results and input content, and their hashes (scheme `sha256_v1`): typed money, rates, discount factors and year fractions, exact half-even rounding; frozen vectors from an independent Python implementation | `devenv shell -- veridian-julia-test` |
| `control_plane/` | The Elixir control plane so far: the calculation-graph ledger in PostgreSQL through Ash (bundled writes, row locks, memo hits), bitemporal input versions with point-in-time resolution, typed scheme-named identifiers, and the `calc_id` encoding | `devenv shell -- veridian-test` (and `veridian-dialyzer`) |

The ledger's rules are a pure state machine that replays the traces of
`models/calc_graph.qnt` step for step, against the real database as well;
property tests check bundled operations against the same machine; and every
database constraint names the model property, model type or spec construct it
enforces (`docs/design/decisions.md`, D-072 to D-082). The tests use a
throwaway PostgreSQL cluster under `~/.local/state/veridian-test`, started and
stopped by the script.

## Implement it in your language

The specs describe behaviour, not a programming language, but they assume two
roles (a control plane and a compute plane) and name the technology we chose
for them. See [PORTING.md](PORTING.md) for the mapping and for what an
implementation must guarantee.

## Status and limits

- The platform is being built against these specifications. What is published
  is the first slice: the canonical-form package, the ledger and input
  versions. Workers, dispatch, identities and the front ends are not built yet;
  trace replay exists for `models/calc_graph.qnt` only. No pricing or
  regulatory calculation is implemented, so the regulation chains above end at
  the specification for those.
- The models are checked by random simulation. A model covers a small instance,
  so absence of a violation is evidence, not proof. Exhaustive checking with
  Apalache was tried and is not yet practical at useful depth
  (`models/README.md`).
- The environment is declared in Nix, but the lock file that pins every input
  is not published, so a fresh clone may resolve different versions.
- Throughput was measured on a shared laptop
  (`docs/design/local-measurements.md`): with bundles of 100, the whole ledger
  path runs at about 1,200 to 1,400 nodes per second with durable commits (5,200
  with bundles of 500), bound by commit rate; CPU cost was compared by statement
  counts and process CPU, not wall time. A laptop spike measured dispatch
  overhead, ledger throughput and Slurm behaviour; its report is
  `docs/design/spike-report.md`, and the prototype code is not published.
- Open questions are recorded in each spec as `open question` blocks.
- The regulatory extracts and reference values used while drafting are not
  redistributed here; see `docs/regulatory/README.md`.

## Licence and credits

Copyright 2026 Alba Intelligence Ltd. Apache-2.0, see [LICENSE](LICENSE) and
[NOTICE](NOTICE). Allium is a specification language by JUXT; Quint is by
Informal Systems; TLA+ is by Leslie Lamport. Not affiliated with any of them.

Feedback is welcome as issues, especially on the open questions.
