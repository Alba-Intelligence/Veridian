# Implementing the specifications in another language

The specifications describe behaviour in domain terms. They assume **two
roles** and, in places, name the technology chosen for each. Implementing them
in Rust, Go, Java or Kotlin means filling the same two roles; the names below
are a mechanical rename, not a change of design.

## The two roles

| Role in the specs | Named in the specs as | What it owns |
|---|---|---|
| Control plane (Veridian Fabric) | Elixir (BEAM) | the calculation graph and ledger, scheduling, bitemporal resolution of inputs, supervision of workers, release control, audit, web front end |
| Compute plane (Veridian Core) | Julia | pricing and risk models, calendars and date conventions, planning of a calculation's steps, schemas of inputs |

Where the specs say "Julia" or "Elixir", read "compute plane" or "control
plane". The compute plane is a black box that takes inputs and returns a
result and a result hash; the control plane never interprets a calendar or a
model, and the schemas of trades, market objects and reference data are
generated from the compute plane's types, which the control plane reads as
opaque data.

## Where specs name technology

| Spec | Names | Meaning for a port |
|---|---|---|
| 01, 02, 03, 05, 06, 08, 09, 10, 13, 14, 16, 17, 18, 22 | Julia (and Elixir in 02, 03, 06) in scope notes and comments: who owns calendars, planning, payload schemas, model code | the two roles above |
| 15, 20 | import `07-julia-workers.allium` by file name; 20 lists the control plane as application code and the worker build as a Julia system image | the file name is historical; read it as "compute workers" |
| 07 workers | Julia worker processes, Slurm allocations, Erlang distribution over TLS, a job queue | a **reference deployment**: the protocol (tickets, bundles, heartbeat, drain, commit) is what `models/bundled_dispatch.qnt` models; the scheduler and transport can differ |
| 12 front end | Phoenix LiveView | any server-rendered or single-page front end that meets the same surfaces |
| 11 | Slurm in a comment on the grid | same as spec 07 |

## What an implementation must guarantee

These are requirements the models fix; each is stated in `models/README.md` and
the spec it names.

1. **One transaction per ledger step.** In the calculation graph the unique
   `calc_id` and the conditional state change happen in one transaction (spec 02,
   `calc_graph.qnt`). A bundle of results is committed in one transaction, and
   a reported result is not final until that commit (spec 07,
   `bundled_dispatch.qnt`).
2. **Check and activate a release atomically.** Evaluation of a release (the
   gate check and the activation, which replaces the previous active release)
   is one atomic step (specs 05 and 21, `release_gate.qnt`).
3. **Liveness is decided by the control plane's own heartbeat**, not by the
   scheduler. A host silent past the timeout is declared lost, every job it held
   is treated as crashed and retried, and a late report from it is ignored.
4. **Results are deterministic and content-addressed.** The same inputs, model
   version and as-of times give the same result hash, across restarts and thread
   counts. A purged result that is recomputed must reproduce its hash, otherwise
   a reproducibility breach is raised.
5. **One recomputation per purged result**, however many steps wait for it.
   What happens when that recomputation is lost (retry up to a bound, then fail
   the waiting steps) is recorded as an open question in spec 02.
6. **Independence rules hold**: release author and reviewers, validator and
   model owner, breach reviewer and owner are different people.

## Checking a port

Replaying the models' traces against the implementation is the intended
conformance method (`docs/design/spec-and-model-policy.md`, section 7): the
model writes traces, an adapter maps each model action to a call on the real
components, and a test compares the model's state with a projection of the
real state after every step. A difference is a finding.
