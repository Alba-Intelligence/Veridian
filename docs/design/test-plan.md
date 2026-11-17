# Test plan: tests propagated from the specs

Status: 2026-11-15. The five choices in section 6 were answered by the user
and are recorded as D-049; the rest of the plan remains a proposal. Prepared from `allium plan` over the 19
specs in `specs/` (main at `a56231a`), plus the contract `@invariant` and
`@guarantee` annotations, which `allium plan` does not turn into obligations.

## 1. What exists and what does not

There is no production code. The only code is the laptop spike under `spike/`
(Elixir control plane prototype, Julia worker, a Postgres ledger), and its
tests are a few ExUnit files (`spike/elixir/test/`) and `julia/selftest.jl`.
They cover a thin slice of specs 02 and 07 (memoization on a second run,
determinism, bundled dispatch) and are reused as they are, not regenerated.

So this plan does two things: it sizes and orders the test work the specs imply,
and it fixes how each kind of obligation will be tested, so that test code can
be written beside each spec's implementation, not afterwards. Writing about
1,100 failing stubs against interfaces that do not exist yet would produce
noise, so stubs are generated per spec when its implementation starts.

## 2. Inventory

Counts of the obligations `allium plan` derives from structure, and of the
behavioural annotations it does not count.

| Spec | Plan obligations | Contract `@invariant` | `@guarantee` | Open questions |
|---|---:|---:|---:|---:|
| 01 bitemporal data | 68 | 0 | 1 | 3 |
| 02 calculation graph | 136 | 5 | 0 | 3 |
| 03 calendars and conventions | 8 | 9 | 1 | 2 |
| 04 identity, access, audit | 131 | 0 | 2 | 1 |
| 05 configuration and release | 37 | 0 | 1 | 1 |
| 06 batch scheduling | 96 | 0 | 0 | 1 |
| 07 Julia workers | 176 | 21 | 0 | 0 |
| 08 market objects | 3 | 6 | 1 | 1 |
| 09 IRS pricing | 2 | 6 | 1 | 1 |
| 10 data ingestion, synthetic data | 64 | 0 | 2 | 2 |
| 11 FRTB standardised approach | 14 | 9 | 1 | 0 |
| 12 web front end, batch console | 18 | 5 | 0 | 0 |
| 13 report review, alerts, trends | 84 | 0 | 0 | 1 |
| 14 trader dashboards | 51 | 3 | 0 | 0 |
| 15 compute cost accounting | 62 | 0 | 0 | 0 |
| 16 trade and reference data | 58 | 5 | 0 | 1 |
| 17 bond pricing | 2 | 12 | 2 | 4 |
| 18 equity option pricing | 2 | 10 | 2 | 4 |
| 19 regulatory reports | 76 | 7 | 1 | 5 |
| **Total** | **1,088** | **98** | **15** | **30** |

The plan's 1,088 obligations by category: rule failure 327, rule success 188,
transition edge 92, rule entity creation 60, optional-field handling 50,
entity fields 49, surface actor 41, state-dependent field presence 36, config
default 33, surface provides 30, rejected transition 27, surface exposure 27,
contract signature 27, terminal state 25, temporal 23, invariant 22, entity
relationship 9, derived 7, projection 5, enum comparability 4, `when` set 4,
`when` clear 2.

Reading the table: the pricing and market specs (08, 09, 11, 17, 18) show
almost no plan obligations because their substance is in contract annotations
(113 across all specs). Those are the highest-risk tests in a bank and need
explicit cases, not a derived list. The control-plane specs (02, 04, 06, 07,
13, 15, 19) are the opposite: many structural obligations, mostly mechanical.

## 3. How each kind of obligation is tested

| Obligation | Test kind | Tools (proposed) |
|---|---|---|
| Rule success and failure, entity creation, fields, optionals, state-dependent fields | Assertion tests per rule, one fixture per case | ExUnit (Elixir); `Test` (Julia) |
| Transition edges, rejected transitions, terminal states | State machine tests: an action map per edge, random walks over the graph checking invariants at every step | ExUnit with StreamData |
| Top-level invariants (22) | Property tests over generated sequences of rules | StreamData; Supposition.jl for Julia code |
| Surface actor, exposure, provides | Boundary tests through the web or API layer with a user of each role | ExUnit against the web layer (12) |
| Config defaults | One test reading each default from the config artefact | ExUnit |
| Temporal (23): deadlines, escalations, heartbeat timeouts | Controllable clock, never sleeping | Injected clock (see gaps) |
| Contract signatures (27) | Compile-time or startup conformance check of each Julia contract against its Elixir caller | Contract fixtures shared by both sides |
| Contract `@invariant` and `@guarantee` of pricing and market specs | Golden-vector tests, independent cross-check, property tests (below) | Julia `Test`, QuantLib reference output, Supposition.jl |
| Cross-spec trigger chains | Integration tests wiring the participating components | A shared integration fixture |

Principles from earlier decisions, applied to every test:

- **F-1.** Tests never read live or retained platform data. Each carries its
  own frozen inputs and expected outputs, content-addressed and archived with
  the release; stores, feeds, workers and the clock are replaced by fakes
  (Mox for Elixir behaviours, Mocking.jl and multiple dispatch for Julia).
- **D-010.** Data classes never mix in one calculation, and the golden,
  synthetic and test sets are deliverables. A test that mixes classes is a
  defect in the test, and one test per computation path proves a mixed input
  is rejected.
- **D-015 and F-3.** Rounding for hashing and prescribed rounding for formulas
  are tested separately. Each prescribed formula has a test citing its source.
- **Determinism (02).** Every Julia result is hashed; each model has a test
  that runs it at different thread counts, after a worker restart, and with
  and without the system image, and expects one hash (the spike did this for
  three models).

### 3.1 Property tests that follow from the pricing specs

These need no reference implementation and catch whole classes of errors:

- Bonds (17): a callable bond is never worth more than the same straight
  bond; a far-out-of-the-money call is worth nothing; a zero-spread credit
  curve gives the risk-free PV; the straight bond inside the lattice
  reproduces the closed-form PV; clean plus accrued equals dirty.
- Options (18): American is never below European, and equal without dividends;
  value is monotone in spot and volatility; put-call parity is not testable
  (calls only), so the intrinsic-value floor is tested instead.
- Market objects (08): every calibrated object reprices its input quotes
  within tolerance; discount factors are positive and survival probabilities
  non-increasing; shocking and un-shocking returns the base object.
- IRS (09): par rate gives zero PV; a payer and a receiver swap offset.
- FRTB (11): the capital is the largest of the three correlation scenarios;
  a perimeter with one position equals that position's standalone charge;
  scaling every sensitivity by k scales the delta charge by the absolute
  value of k (the aggregation is positively homogeneous).
- Reports (19): a report rebuilt from retained figures has the same file hash;
  a restated report lists exactly the cells whose value differs.

### 3.2 Golden vectors and the independent cross-check

D-010 and the pricing specs require golden valuations reproduced
independently (QuantLib) before a model version enters a production release.
That means a reference run outside Julia that produces frozen expected values
(IRS, bullet and callable bonds, European and American calls, curve
calibration, FRTB sensitivities for small portfolios). The reference outputs
are archived as fixtures and are never recomputed in CI. Tolerance per
instrument is stated beside each fixture.

## 4. Order of work

Follows the dependency order, not the size of the table:

1. **Foundation: 01, 02, 03, 07.** Everything depends on them and the spike
   already proved parts of 02 and 07. The determinism and memoization tests
   of the spike become the first regression tests. 03's golden calendars and
   day-count vectors start here, in Julia, independent of Elixir.
2. **Money correctness, in parallel, in Julia only: 08, 09, 17, 18, then 11.**
   Golden vectors and the property tests above can be written as soon as the
   Julia package exists, without the control plane. These are the tests the
   bank's model risk function will ask to see.
3. **Control and governance: 04, 05, 06, 10, 16.** Mostly state machine and
   rule tests; four-eyes, break-glass, and audit chaining are security
   properties and get property tests with generated user sequences.
4. **Outputs: 12, 13, 14, 15, 19.** Mostly boundary and rule tests; the
   report file tests need the golden-file fixtures of 19.

## 5. Infrastructure the specs demand

These are gaps to close before the tests can be written, not tests:

- **Injectable clock.** 23 temporal obligations (heartbeat timeout, capacity
  lead, sign-off escalation, deadlines) cannot be tested without a clock the
  tests control. Every Elixir component that reads time must take it through
  one behaviour (mockable with Mox); the plan does not allow sleeping.
- **Integration fixture for cross-spec chains.** The spec check lists 25
  triggers that nothing local emits; 10 are explicitly imported from another
  spec. Each is a cross-component chain (for example release activation
  registering schedules, perimeters, templates and rate cards). One fixture
  that wires the control plane with a fake worker pool serves them all.
- **Action maps for the 92 transition edges.** One function per edge that
  puts an entity in the source state and applies the witnessing rule.
- **Synthetic data generators (10).** The test and synthetic data classes are
  deliverables and double as test inputs; generators must be seeded and
  hashed.
- **Reference runs.** A reproducible way to produce the QuantLib golden
  outputs, kept outside the platform's runtime, with its inputs frozen.
- **Performance gates.** The spike's targets (D-043) are measurements, not
  unit tests: dispatch, ledger commit rate, worker start, determinism. They
  run on demand against the spike's benchmark harness and record numbers with
  the Syncthing and I/O conditions stated.

## 6. Choices (decided, D-049)

Answered by the user on 2026-11-15; each is the option this plan proposed.

1. **Where tests live: beside the code.** Each Elixir app's `test/` and each
   Julia package's `test/`, with fixtures under one `fixtures/` tree per
   component, changed in the same commit as the code they cover.
2. **Property-testing libraries: StreamData (Elixir) and Supposition.jl
   (Julia).** Upstream-contributable packages must follow each JuliaActuary
   package's own contribution standards (to be checked per package; I have not
   verified which test library each uses), so the property tests live in our
   own packages until then.
3. **Spec-first for the Julia pricing code, code-first for the control
   plane.** The pricing specs are precise and the golden vectors exist
   independently of the code, so failing tests come first; control-plane
   interfaces will change when the first version is built, so its tests follow
   the code.
4. **Reference run: Claude writes and runs it once with QuantLib via Python,
   the user reviews the vectors.** The script lives outside the platform
   runtime; outputs are frozen as fixtures with their inputs and tolerances.
   QuantLib is added to the devenv for this, which needs a package download
   but no other network call.
5. **Continuous integration: the local devenv shell only for now.** One
   Nix-managed devenv script runs every test, with no cloud and no external
   service; a bank CI system can call the same script later.

## 7. Not covered by this plan

- Obligations from the 30 open questions: they become tests when answered.
- Runtime trace checking and model checking: separate workstreams.
- Penetration and load testing of the production environment: spec 20
  (production operations) sets recovery drills, and sizing is open there;
  testing of the production environment itself is a later task.
