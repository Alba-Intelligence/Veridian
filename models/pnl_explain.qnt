// -*- mode: Quint -*-
//
// P&L runs, the residual and its review (spec 26, D-069): each published batch
// run starts a P&L against the run before it; a residual beyond tolerance is a
// finding accepted by someone not responsible for the book; a restatement
// replaces the P&L of the day and of the next day.
//
// What is modelled: days 1..N published in order (day 1 has no prior run);
// per day one current P&L run with its state; values of HPL and RTPL, the
// residual and its disposition against a tolerance; the alert for a finding
// left open past its due time; restatements.
//
// What is not modelled: the components, currencies, nodes of the hierarchy,
// calc_ids, the reported figures, actual P&L.
//
// Authority (D-055): authoritative for the behaviour it covers. `pnl` is the
// behaviour; each `pnl_mutant_*` removes one control and the gate requires the
// matching property to fail:
// `no_prior_check` (day 1 gets a P&L; computedHasPrior),
// `bad_residual` (residual is not hpl - rtpl; residualConsistent),
// `no_independence` (the responsible person accepts; acceptorIndependent),
// `no_alert` (an overdue finding stays silent; overdueAlerted),
// `no_supersede` (a restatement leaves two current runs; oneCurrent).

module pnl_explain {
  const DAYS: Set[int]
  const USERS: Set[str]
  const RESP: str                 // the person responsible for the book
  const TOL: int                  // absolute tolerance of the residual
  const MUTANT: str

  type PSt = | NoRun | Pending | Computed | Unavailable
  type Fin = | NoFin | Within | Open | Accepted

  var published: int -> bool
  var st: int -> PSt
  var curCount: int -> int         // current (not superseded) runs of the day
  var fin: int -> Fin
  var hpl: int -> int
  var rtpl: int -> int
  var res: int -> int
  var due: int -> bool             // the review window has elapsed
  var alerted: int -> bool
  var accBy: int -> str

  def first(d: int): bool = d == 1

  action init = all {
    published' = DAYS.mapBy(d => false),
    st' = DAYS.mapBy(d => NoRun),
    curCount' = DAYS.mapBy(d => 0),
    fin' = DAYS.mapBy(d => NoFin),
    hpl' = DAYS.mapBy(d => 0),
    rtpl' = DAYS.mapBy(d => 0),
    res' = DAYS.mapBy(d => 0),
    due' = DAYS.mapBy(d => false),
    alerted' = DAYS.mapBy(d => false),
    accBy' = DAYS.mapBy(d => ""),
  }

  // A run is published: its P&L starts, against the run before it.
  // spec: 26-pnl-and-explain#StartPnl, 26-pnl-and-explain#RequestPnl
  action publish(d: int): bool = all {
    not(published.get(d)),
    d == 1 or published.get(d - 1),
    published' = published.set(d, true),
    st' = st.set(d, if (first(d) and MUTANT != "no_prior_check") Unavailable else Pending),
    curCount' = curCount.set(d, 1),
    fin' = fin, hpl' = hpl, rtpl' = rtpl, res' = res,
    due' = due, alerted' = alerted, accBy' = accBy,
  }

  // The result: a finding, within tolerance or open.
  // spec: 26-pnl-and-explain#PnlCompletes
  action complete(d: int, h: int, r: int): bool = {
    val residual = if (MUTANT == "bad_residual") h - r + 1 else h - r
    val absRes = if (residual < 0) -residual else residual
    all {
      st.get(d) == Pending,
      st' = st.set(d, Computed),
      hpl' = hpl.set(d, h),
      rtpl' = rtpl.set(d, r),
      res' = res.set(d, residual),
      fin' = fin.set(d, if (absRes <= TOL) Within else Open),
      published' = published, curCount' = curCount,
      due' = due, alerted' = alerted, accBy' = accBy,
    }
  }

  // spec: 26-pnl-and-explain#PnlFails
  action failPnl(d: int): bool = all {
    st.get(d) == Pending,
    st' = st.set(d, Unavailable),
    published' = published, curCount' = curCount, fin' = fin, hpl' = hpl,
    rtpl' = rtpl, res' = res, due' = due, alerted' = alerted, accBy' = accBy,
  }

  // spec: 26-pnl-and-explain#AcceptResidual
  action accept(d: int, u: str): bool = all {
    fin.get(d) == Open,
    MUTANT == "no_independence" or u != RESP,
    fin' = fin.set(d, Accepted),
    accBy' = accBy.set(d, u),
    published' = published, st' = st, curCount' = curCount, hpl' = hpl,
    rtpl' = rtpl, res' = res, due' = due, alerted' = alerted,
  }

  // The review window elapses: an open finding alerts its owner.
  // spec: 26-pnl-and-explain#FindingOverdue
  action tick(d: int): bool = all {
    not(due.get(d)),
    fin.get(d) == Open,
    due' = due.set(d, true),
    alerted' = if (MUTANT == "no_alert") alerted else alerted.set(d, true),
    published' = published, st' = st, curCount' = curCount, fin' = fin,
    hpl' = hpl, rtpl' = rtpl, res' = res, accBy' = accBy,
  }

  def hit(d: int, x: int): bool = x == d or x == d + 1

  // A restatement of day d replaces the P&L of day d and of day d + 1 (which
  // compares against it): the old runs are superseded, new ones start.
  // spec: 26b-pnl-restatement-and-review#SupersedeOnRestatement, 26b-pnl-restatement-and-review#RestartPnl
  action restate(d: int): bool = {
    all {
      published.get(d),
      st' = DAYS.mapBy(x =>
        if (hit(d, x) and published.get(x)) (if (first(x)) Unavailable else Pending) else st.get(x)),
      curCount' = DAYS.mapBy(x =>
        if (hit(d, x) and published.get(x) and MUTANT == "no_supersede") curCount.get(x) + 1
        else curCount.get(x)),
      fin' = DAYS.mapBy(x => if (hit(d, x) and published.get(x)) NoFin else fin.get(x)),
      due' = DAYS.mapBy(x => if (hit(d, x) and published.get(x)) false else due.get(x)),
      alerted' = DAYS.mapBy(x => if (hit(d, x) and published.get(x)) false else alerted.get(x)),
      published' = published, hpl' = hpl, rtpl' = rtpl, res' = res, accBy' = accBy,
    }
  }

  action step = {
    nondet d = DAYS.oneOf()
    nondet u = USERS.oneOf()
    nondet h = Set(0, 3, 9).oneOf()
    nondet r = Set(0, 3, 8).oneOf()
    any { publish(d), complete(d, h, r), failPnl(d), accept(d, u), tick(d), restate(d) }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // spec: 26-pnl-and-explain#ResidualIsDifference, 26-pnl-and-explain#ExplainAddsUp
  val residualConsistent = DAYS.forall(d =>
    st.get(d) != Computed or res.get(d) == hpl.get(d) - rtpl.get(d))

  // spec: 26-pnl-and-explain#ComputedHasPrior
  val computedHasPrior = DAYS.forall(d =>
    d > 1 or (st.get(d) != Pending and st.get(d) != Computed))

  // spec: 26-pnl-and-explain#AcceptorIsIndependent
  val acceptorIndependent = DAYS.forall(d => fin.get(d) != Accepted or accBy.get(d) != RESP)

  // A finding left open past its window has alerted.
  val overdueAlerted = DAYS.forall(d => not(due.get(d) and fin.get(d) == Open) or alerted.get(d))

  // spec: 26b-pnl-restatement-and-review#OneCurrentPnlRun
  val oneCurrent = DAYS.forall(d => curCount.get(d) <= 1)

  val safety = and {
    residualConsistent, computedHasPrior, acceptorIndependent, overdueAlerted, oneCurrent,
  }

  // Witness, meant to be violated: a finding is accepted.
  val notAccepted = not(DAYS.exists(d => fin.get(d) == Accepted))
}

module pnl {
  import pnl_explain(DAYS = Set(1, 2, 3), USERS = Set("ann", "bo"), RESP = "ann", TOL = 1, MUTANT = "").*
}

module pnl_mutant_no_prior_check {
  import pnl_explain(DAYS = Set(1, 2, 3), USERS = Set("ann", "bo"), RESP = "ann", TOL = 1, MUTANT = "no_prior_check").*
}

module pnl_mutant_bad_residual {
  import pnl_explain(DAYS = Set(1, 2, 3), USERS = Set("ann", "bo"), RESP = "ann", TOL = 1, MUTANT = "bad_residual").*
}

module pnl_mutant_no_independence {
  import pnl_explain(DAYS = Set(1, 2, 3), USERS = Set("ann", "bo"), RESP = "ann", TOL = 1, MUTANT = "no_independence").*
}

module pnl_mutant_no_alert {
  import pnl_explain(DAYS = Set(1, 2, 3), USERS = Set("ann", "bo"), RESP = "ann", TOL = 1, MUTANT = "no_alert").*
}

module pnl_mutant_no_supersede {
  import pnl_explain(DAYS = Set(1, 2, 3), USERS = Set("ann", "bo"), RESP = "ann", TOL = 1, MUTANT = "no_supersede").*
}
