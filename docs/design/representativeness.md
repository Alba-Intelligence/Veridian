# Is IRS representative? Bond and equity call as reference instruments

Date: 2026-11-14. Decision D-021: specs are designed against all three
instruments; IRS is implemented first.

## The three reference instruments

| | Vanilla IRS | Fixed-coupon corporate bond | European equity call |
|---|---|---|---|
| Pay-off | linear in rates | linear in rates and credit spread, plus default | non-linear (optionality) |
| Market inputs | OIS and forward curves, fixings | risk-free curve, issuer spread or hazard curve, bond price quotes | spot, dividends, repo/borrow rate, implied volatility surface, risk-free curve |
| Calibration | bootstrap curves from par quotes | fit spread (z-spread) to the price: an inverse problem | fit a volatility surface to option quotes, with no-arbitrage checks |
| Reference data | calendars, conventions | issuer, seniority, rating, sector, country (all change over time) | underlying, exchange, corporate actions (splits, special dividends) |
| Life-cycle events | fixings, payments, early termination | coupons, calls/puts, default and recovery, restructuring | exercise, expiry, contract adjustment after corporate actions |
| FRTB-SA risk classes | GIRR delta (vega and curvature only if optional) | GIRR delta, CSR non-securitisation delta, Default Risk Charge (jump-to-default) | Equity delta, vega, curvature; GIRR delta; residual risk add-on only for exotics |
| Typical model | discounting | discounting with survival, or spread discounting | Black-Scholes (European); trees, PDE or Monte Carlo later (American, exotic) |

## What IRS alone does not exercise, and the platform consequence

1. **Non-linear risk and curvature.** FRTB curvature reprices each position under
   up and down shocks per risk factor. Shocked market objects are derived nodes
   (shock function applied to a curve or surface), so curvature is many
   evaluation nodes sharing unshocked prerequisites. Memoization and early
   cutoff pay off most here. Spec 02 already supports this; the FRTB spec must
   plan shocks as ordinary steps.
2. **Two-dimensional, calibrated market objects.** Volatility surfaces (strike
   by expiry) and spread curves are calibrated from quotes. Calibration is a
   node like curve bootstrapping, but it is an optimisation with tolerances, so
   the canonical-rounding contract (D-004, D-015) is what makes its result_hash
   stable. Calibration failure (no arbitrage-free fit) is a deterministic
   rejection, not a crash.
3. **Monte Carlo and solvers.** Options beyond European need Monte Carlo or
   PDE solvers. Determinism needs seeds derived from calc_id, fixed thread
   reduction order and canonical rounding. Already in the DeterministicComputation
   contract; must be tested with a Monte Carlo golden case.
4. **Credit reference data that changes over time.** Ratings, sector and
   seniority drive FRTB CSR buckets and DRC risk weights. They are bitemporal
   reference data (an issuer downgrade is a new version effective at a date).
   Fits spec 01 unchanged.
5. **Default as an event.** Jump-to-default and recovery introduce a
   discontinuous outcome and a terminal trade state. DRC is a separate charge
   with its own aggregation (long/short netting by obligor and seniority).
6. **Life-cycle events versus corrections.** An exercise, a call by the issuer,
   a default or a corporate action is a new business fact effective from a date,
   not an error fix. Spec 01 today offers only "new version" (no overlap allowed)
   and "correction" (four-eyes). A life-cycle event on an open-ended trade
   version must end the previous version's validity without being treated as a
   correction. See open question Q-A.
7. **Price quotes versus rate quotes.** Bonds are quoted clean or dirty, in
   price or yield; accrued interest and ex-coupon rules matter. Purely
   instrument-level (Julia, D-018); no platform impact.
8. **Several currencies.** A USD bond or a HKD equity option in a EUR-reporting
   book needs FX spot rates for FRTB aggregation and an FX risk class. FX rates
   are ordinary bitemporal series; the FRTB spec must include FX delta.
9. **Equity corporate actions.** A split or special dividend adjusts the option
   contract (strike, multiplier). This is a life-cycle event on the trade
   triggered by a reference-data event on the underlying (see Q-A).

## Verdict

IRS is representative of the **platform** (bitemporal inputs, calculation
graph, worker contract, memoization, planning). It is **not** representative
of: curvature and shocked scenarios, calibrated two-dimensional market objects,
stochastic models, credit reference data and default, life-cycle events, and
multi-currency aggregation. None of these needs a different platform; items 1,
2, 3, 4, 7, 8 already fit specs 01 and 02. Item 6 (life-cycle events) needs a
change to spec 01. Items 5 and 8 shape the FRTB spec.

Consequences for the plan:
- Golden and synthetic test portfolios contain all three instruments from the
  start, even before bond and option pricing exist (planning and data tests).
- The FRTB spec is written generically (risk class, bucket, risk factor,
  sensitivity type, DRC) rather than GIRR-only, with GIRR implemented first.
- Suggested implementation order: IRS (GIRR delta), bond (CSR delta, DRC),
  European equity call (equity delta, vega, curvature).

## Answers (2026-11-14)

- Q-A: Succession adopted as recommended (D-023, assumed; not explicitly answered).
- Q-B: both fixed-coupon bullet and callable bonds in v1 (D-022).
- Q-C: both European and American calls in v1 (D-022).
- Q-D: DRC in v1 (D-022).

## Open questions (original wording)

- Q-A: Life-cycle events. Proposal: a third operation, `Succession`, records a
  new fact that ends the current version at an effective date and starts a new
  one, with its own approval policy (single approver, or automatic from an
  authoritative feed), distinct from four-eyes corrections.
- Q-B: Bond scope: fixed-coupon bullet only for v1, or callable bonds as well
  (callables add optionality, so bond vega and curvature)?
- Q-C: Option scope: European only for v1 (closed form), or American as well
  (trees or PDE)?
- Q-D: DRC in v1 scope with the bond, or later?
