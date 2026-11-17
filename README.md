# Veridian Spec

**Veridian: regulation, formalized. Computation, verified.**

Specifications and executable protocol models for Veridian, a
risk-calculation platform for bank market-risk regulation: content-addressed
calculations recorded in a ledger, bitemporal data, a tamper-evident audit
log, four-eyes release control and independent model validation.

This repository is **Veridian Spec**: the specifications and the models, not
the platform. It exists to show how a system with two very different halves
can be specified precisely, checked by tools, and reviewed by people who do
not read code.

| Component | Role |
|---|---|
| Veridian Spec | LLM-assisted Allium and Quint specification drafting (this repository) |
| Veridian Fabric | Elixir-based computation distribution plane (the control plane below) |
| Veridian Core | Julia-based numerical computing plane (the compute plane below) |
| Veridian Ledger | provenance, audit trail and regulatory traceability |

## Why two formalisms

A platform like this needs two ways of thinking at once.

- The **control plane** is about time, concurrency and failure: hosts die,
  messages arrive late, two things happen at once. Its protocols are modelled in
  [Quint](https://quint-lang.org) (semantics of TLA+), in `models/`, and checked
  by random simulation.
- The **computation plane** and the domain are about definitions: what a
  regulation says a number is, what a pricing model must return for given
  inputs. They are specified in Allium, a behavioural specification language,
  in `specs/`, in domain terms.

The two are tied together: a rule in a spec that a model covers carries a
`-- model:` tag, the matching model element carries a `// spec:` tag, and a
check fails if either side is missing. For what a model covers, the model is
authoritative and the spec describes it (`docs/design/spec-and-model-policy.md`).

Both were drafted with an LLM coding agent and then checked mechanically. The
effort of getting from an informal idea to a precise specification is what
used to make this approach rare.

## What the models found

- **Stranded results (spec 07, `models/bundled_dispatch.qnt`).** Workers report
  results one by one, but the ledger commits a bundle in a single transaction
  at the end. If a host was declared lost between the first report and the
  commit, the reported results belonged to nobody and were never recomputed.
  Shortest case: a bundle of two nodes, one report, one lost host. The spec now
  keeps a reported result on its ticket until the bundle commits.
- **Recomputation stampede (spec 02, `models/calc_graph.qnt`).** The spec said
  one recomputation per purged result; with n steps waiting, the model showed
  n. A step bound to a node already marked irreproducible also triggered a
  recomputation. Both are fixed.
- **Release gate (specs 05 and 21, `models/release_gate.qnt`).** One lapsed
  validation blocked every new release, even one that changed no model. Decided:
  the gate looks only at the model versions a release adds or changes.

The old behaviour stays in each model as a *negative control* (a `mutant`
instance), and the gate requires the checks to still catch it.

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

## Run the checks

```
devenv shell -- veridian-spec-check
```

This runs `allium check` on all specs, the two-way traceability check, and the
model checks (random simulation, 20000 runs per check by default;
`VERIDIAN_QUINT_RUNS` changes it). Needs [devenv](https://devenv.sh) (Nix).
All specs are checked together: a single spec alone gives spurious
unresolved-reference warnings.

## Implement it in your language

The specs describe behaviour, not a programming language, but they assume two
roles (a control plane and a compute plane) and name the technology we chose
for them. See [PORTING.md](PORTING.md) for the mapping and for what an
implementation must guarantee.

## Status and limits

- Specifications and models only. The platform is to be built against them;
  the next step for the models is replaying their traces against the real
  code.
- The models are checked by random simulation. A model covers a small instance,
  so absence of a violation is evidence, not proof. Exhaustive checking with
  Apalache was tried and is not yet practical at useful depth
  (`models/README.md`).
- Open questions are recorded in each spec as `open question` blocks.
- A laptop spike measured dispatch overhead, ledger throughput and Slurm
  behaviour (host-loss detection by our heartbeat in about 5 s against about 50 s
  for Slurm itself). Its report is `docs/design/spike-report.md`; the prototype
  code is not published.
- The regulatory extracts and reference values used while drafting are not
  redistributed here; see `docs/regulatory/README.md`.

## Licence and credits

Copyright 2026 Alba Intelligence Ltd. Apache-2.0, see [LICENSE](LICENSE) and
[NOTICE](NOTICE). Allium is a specification language by
JUXT; Quint is by Informal Systems; TLA+ is by Leslie Lamport. Not affiliated
with any of them.

Feedback is welcome as issues, especially on the open questions.
