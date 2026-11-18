# BCBS 239 mapping (gap review item 10)

Status: written 2026-11-18 from the specs as they stand (specs 01 to 26, decisions D-001 to D-071).
It maps the 14 principles of the Basel Committee's "Principles for effective risk data aggregation and
risk reporting" (BCBS 239, 2013) to what the specs say, and names what is missing. It is not a
compliance statement: the principles apply to the bank, and Veridian supplies part of the evidence.
Strength: **strong** (specified and checked in a model or invariant), **specified** (rules and
invariants in a spec, not modelled), **partial** (some of the principle is covered), **gap**.

The wording of each principle is a short paraphrase. Check against the Committee's text before this
document is used outside the project.

## Overarching governance and infrastructure

| # | Principle | Where in the specs | Strength | What is missing |
|---|---|---|---|---|
| 1 | Governance: senior management owns and resources the data framework, with independent validation | Roles, grants with four eyes, step-up authentication (04); independent model validation, benchmark runs and breaches (21, 21b, 21c); release review with a reviewer other than the author (05, 24); named business owners of every data source (10 `data_owner`); decision log (decisions.md) | specified | Board-level reporting on the framework itself; an owner for the data framework as a whole (it is a bank process, not a platform feature) |
| 2 | Data architecture and IT infrastructure support aggregation under stress and in crisis | One calculation graph for every figure (02); bitemporal inputs (01); high-availability and restore targets with drills (20, 20c: RPO 0, RTO 1 hour as placeholders); capacity from the bank's grid with elasticity and a regulatory peak (07c); stress runs (25, 25b) | partial | Regional replicas and a disaster-recovery site (gap 9); a measured stress test of the platform under a crisis load (spike did not measure it) |

## Risk data aggregation capabilities

| # | Principle | Where in the specs | Strength | What is missing |
|---|---|---|---|---|
| 3 | Accuracy and integrity: aggregation is largely automated, with few manual steps, reconciled | One path from input to figure, no manual edits of a result (02: nodes are immutable, corrections create new versions, 01); every correction needs approval (01b); reconciliation of feeds against control totals (16); golden data sets for models (10b); benchmark runs against independent results (21c); content hash and determinism checks (02, 02c) | strong | Reconciliation to the general ledger (out of scope, gap review); data-quality rules on market data (gap 5) |
| 4 | Completeness: all material risk data is captured, by book, desk, entity and risk type | End-of-day snapshots prove completeness with control totals (16); runs refuse unresolved inputs up front (02, D-008); the perimeters of FRTB and the simplified approach (11, 22); the hierarchy is the entity master (04, 16) | specified | Trading and banking book boundary (gap 11) decides which positions enter; XVA and counterparty credit risk are out of scope (D-002) |
| 5 | Timeliness: aggregation on time, in normal and stress periods | Scheduled batch runs with a cut-off and a deadline, late-start notification and escalation (06); missed runs start on their own at the same cut-off (D-029); regulatory runs get priority capacity (07c, D-039); report deadlines with warnings (19b) | specified | Measured throughput at production size (spike: partial); no schedule dependencies across jobs (D-029, gap 12) |
| 6 | Adaptability: ad-hoc and forward-looking requests on demand | Desk views and what-if (14); ad-hoc stress runs on approved scenario sets (25b); governed scenario register (25); ephemeral tier so ad-hoc work does not grow the ledger (23); release impact before a change (24) | specified | A quant sandbox for candidate models (gap 8); no real-time feeds (D-034) |

## Risk reporting practices

| # | Principle | Where in the specs | Strength | What is missing |
|---|---|---|---|---|
| 7 | Accuracy of reporting: reconciled and validated, with explanations of differences and approximations | Sign-off of every publication, two signers for regulatory ones (13); validation findings and cell differences for regulatory reports (19c); P&L explain with a reviewed residual (26, 26b); impact explanations for a release (24); provenance of every reported figure to its inputs, model code and environment (02, 02d, D-064) | strong | Independent price verification and prudent valuation (gap 6); approximations are not catalogued as such in reports |
| 8 | Comprehensiveness: covers all material risk areas | FRTB sensitivities-based method, default risk charge and residual risk add-on (11); simplified approach (22); P&L (26); stress (25b) | partial | Counterparty credit, XVA, liquidity, concentration and limits are not covered (D-002, gap 7) |
| 9 | Clarity and usefulness: appropriate level of detail, clear, usable | Desk views, console, trend views and alert inbox (12, 13, 13b, 14); every figure carries its data class and as-of and is marked unofficial when it is (12, 14); drill from a figure to its calculation (02d) | specified | No reference dictionary of figure keys beyond the key format of 13 |
| 10 | Frequency: reports as often as risk changes, and on demand in a crisis | Daily batch (06); intraday desk views on every change (14); ad-hoc stress runs (25b); reruns by reproduction or restatement (06b) | specified | Intraday official figures: none in v1 (D-034) |
| 11 | Distribution: timely, with confidentiality preserved | Entitlements by legal entity and book, step-up for approvals, audited reads (04, 04c); sign-off before release to consumers (13); export and submission to regulators with receipt and answer recorded (19b) | specified | Encryption and transport details are the bank's (operating procedures, D-048) |

## Supervisory review, tools and cooperation

| # | Principle | Where in the specs | Strength | What is missing |
|---|---|---|---|---|
| 12 | Review: supervisors review compliance | The audit log with signed, externally anchored checkpoints (04c); auditor read access that is itself audited (04c); the decision log and the traceability between specs and models (spec-and-model-policy.md) | specified | Nothing specified for responding to a supervisor's request beyond the audit and report surfaces |
| 13 | Remedial actions and supervisory measures | Alerts with owners, acknowledgement and escalation (13b); model breaches with reviewed remedy (21c); incidents and recovery review (20); findings that must be accepted by a reviewer (24, 26) | specified | A register of open remediation items across all of these, with owners and dates |
| 14 | Home/host cooperation | Regional reporting calendars and legal entities (03, 04, 16) | gap | Regional closes, host-supervisor reports and follow-the-sun batch (gap 9) |

## Reading the map

- **Strongest:** accuracy and integrity (3), accuracy of reporting (7), and the evidence for review (12): lineage to inputs,
  model and environment is built into the identity of every result.
- **Largest gaps for the bank's own use:** market data quality (5, gap 5), valuation controls (gap 6),
  limits (gap 7), regional resilience (2, 14, gap 9), and the book boundary (4, gap 11).
- **Not a platform feature:** governance of the framework (1), remedial action tracking (13) and
  response to supervisors (12) need bank processes around the evidence the specs produce.
- This map should be re-read whenever a gap is specified; the status column is the place to record it.
