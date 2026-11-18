# JuliaActuary: standards and fit for Veridian

Researched 2026-11-13. Unverified items are marked.

## Contribution standards

- No CONTRIBUTING.md in FinanceModels.jl (404). Guidance lives at
  https://juliaactuary.org/community/: PRs welcome, issues per package repo,
  good-first-issue board https://github.com/orgs/JuliaActuary/projects/2,
  questions via GitHub Discussions or Zulip/Slack #actuary.
- Licence: MIT (FinanceModels, FinanceCore, ActuaryUtilities, others).
- Compat seen in FinanceModels `Project.toml` (master 7.2.0): `julia = "1.10"`,
  `FinanceCore = "3"`, `ForwardDiff = "1"`, `DifferentiationInterface = "0.7.4"`.
  Registry: FinanceCore 3.0.0, FinanceModels 7.0.1, ActuaryUtilities 6.0.0.
- Docs hosted at docs.juliaactuary.org (Documenter-style `docs/` folders);
  CI workflows and Codecov badges present.
- UNVERIFIED: formatter/style (BlueStyle? JuliaFormatter config?), code of
  conduct. Check each repo's `.JuliaFormatter.toml` and CI before the first PR,
  and ask maintainers (Alec Loudenback) on Discussions before large additions.

Our rule: any code meant for upstream must be MIT, match the target repo's
formatter and test layout, carry Documenter docstrings and doctests, keep
ForwardDiff compatibility, and depend only on what the target package already
depends on (or justify a new dep in an issue first).

## Package fit for IRS + FRTB GIRR

| Package | Gives us | Gap |
|---|---|---|
| FinanceCore.jl 3 | `Rate`, `Periodic`, `Continuous`, `Cashflow`, `discount`, `pv` | no day counts, calendars |
| FinanceModels.jl 7 | curves (Spline/MonotoneConvex, NelsonSiegel, SmithWilson), `fit(..., Fit.Bootstrap())` (linear splines only), quotes `ParSwapYield`, `OISYield`; contracts `Bond.Fixed`, `Bond.Floating`, `Composite`, swaptions; `Models(discount; index=...)` multi-curve; ForwardDiff-friendly | no schedules, no fixings/seasoned trades, swap-level worked example unverified |
| ActuaryUtilities.jl 6 | `duration`, DV01, `convexity`, `sensitivities(..., KeyRates(tenors), ...)` via ForwardDiff | key-rate tenors must be mapped to FRTB GIRR vertices by us |
| DayCounts.jl (external) | day-count conventions | not JuliaActuary |
| InterestRates.jl (external, felipenoris) | business-day accuracy, calendars | evaluate licence/maintenance |

## Calendars, day counts, schedules (checked 2026-11-13)

JuliaActuary has none of these. JuliaFinance and others:

| Package | Covers | Status | Licence |
|---|---|---|---|
| BusinessDays.jl | holiday calendars (australia, brazil, canada, germany, target, uk, us files), custom calendars, `CompositeHolidayCalendar` (joint) | active, slow (v0.9.25 Dec 2024; commits Mar 2026) | MIT |
| DayCounts.jl | ACT/360, ACT/365F, ACT/ACT ISDA, ACT/ACT ICMA, 30/360, 30E/360, 30E/360 ISDA; no BUS/252 | stale (2020) | MIT |
| InterestRates.jl | curves, uses BusinessDays | active (v0.6.4 Jul 2026) | MIT |
| QuantLib.jl (pure Julia) | calendars, ModifiedFollowing, schedule generation, Ibor swaps; no SOFR/ESTR compounding | alpha, stale (2020) | MIT |

Gaps nobody covers well: business-day adjustment conventions, roll/EOM/IMM,
stubs, payment and fixing lags, RFR compounding (lookback, observation shift,
lockout). These are prime upstream contributions. Calendars themselves are
data in Veridian (D-017); packages only supply generators and logic.
`Dates.DateTime` is millisecond resolution; see D-015.

## Pricing coverage against the v1 scope (D-022), checked 2026-11-14

FinanceModels.jl (docs: https://docs.juliaactuary.org/FinanceModels/stable/):

| Need | Covered? |
|---|---|
| OIS and forwarding curves, multi-curve, bootstrap/fit | yes |
| Swap legs (`Bond.Fixed`, `Bond.Floating`, `Composite`) | yes (swap worked example unverified) |
| European equity call/put, Black-Scholes-Merton, continuous dividend yield, implied vol fit | yes |
| Short rates: Vasicek, CIR, Hull-White; Hull-White calibrated to swaption quotes (Jamshidian) | yes |
| Monte Carlo with explicit RNG (`simulate(...; rng=...)`) | yes |
| Curve and key-rate sensitivities through `fit` via ForwardDiff | yes |
| Swaptions priced Black or Bachelier on the swap rate (market convention) | **no** |
| American exercise (trees, PDE, Longstaff-Schwartz) | **no** |
| Callable bonds / embedded options | **no** |
| Hazard-rate, survival, credit spread curves, CDS | **no** |
| Equity volatility surfaces (SVI, SABR, local vol), discrete dividends | **no** |
| Vega / option sensitivities | not documented |

EconomicScenarioGenerators.jl is frozen (0.7.1); FinanceModels is its successor.

Alternatives (verified pages only):

| Package | Relevant content | Status |
|---|---|---|
| QuantLib.jl (pazzo83), pure-Julia port | binomial, FD vanilla and MC American engines; Hull-White trinomial tree; tree callable fixed-rate bond engine; hazard-rate and default curves; partial CDS; Heston | self-described alpha; last commit Feb 2020; MIT |
| FinancialDerivatives.jl (JuliaQuant) | European Black-Scholes shown; rest unverified | active (commit Sep 2026); MIT |
| Ito.jl | deprecated, archived 2019 | do not use |
| DiffEqFinancial.jl (SciML) | Heston problem specs | not a pricing library |

No Julia library for SVI/SABR or vol surfaces was found. No maintained binding
to C++ QuantLib was found. Using QuantLib (any form) for production pricing
would weaken D-010, which uses QuantLib as the **independent** cross-check of
golden results.

Build list (what Veridian must write or contribute):
- Upstream candidates (generic): swaption Black/Bachelier pricing; lattice
  (binomial/trinomial) and finite-difference engines; American exercise;
  hazard-rate and survival curves; callable fixed-rate bonds on Hull-White
  trees; equity vol surface types; discrete dividends; vega via AD.
- Veridian-only: curve recipes and calibration orchestration, FRTB shocks,
  bucketing and aggregation, DRC.

## Segregation: candidate upstream contributions vs Veridian-only

Candidate upstream (generic, no Veridian deps):
- Swap schedule generation (dates, roll conventions) and day-count-aware
  cashflows feeding `Bond.Fixed`/`Bond.Floating`.
- Seasoned floating legs with historical fixings.
- A `Swap` contract (fixed vs floating) with worked examples and tests.
- Par-swap bootstrap beyond linear splines.

Veridian-only (separate packages):
- FRTB GIRR vertex mapping, risk weights, correlations, aggregation.
- Worker protocol, Arrow job/result I/O, calc-id hashing, provenance.
- Golden/synthetic data sets and regulatory test fixtures.
