// -*- mode: Quint -*-
//
// The impact gate of a production release (spec 24, with the activation rules
// of spec 05; D-067): a release that changes figures waits for an impact run
// signed off by someone other than its author, and a run goes stale when
// another release activates (a newer published run does not void it, D-067).
//
// What is modelled: releases submitted by an author, some needing an impact run;
// a run that starts, completes with some findings beyond tolerance, whose
// findings are accepted by reviewers other than the author, that is signed off
// or rejected; activation of one release at a time, superseding the previous.
// A run records the active release it was started against.
//
// What is not modelled: the figures themselves, tolerances, replay requests,
// several schedules, scheduled activation and expiry, the model gate (see
// release_gate.qnt), the data class of the replay.
//
// Authority (D-055): authoritative for the behaviour it covers. Instances at
// the bottom: `impact` is the behaviour; each `impact_mutant_*` removes one
// control and the gate requires the matching property to fail:
// `no_base_stale` (an activation does not void runs; gateHeldAtActivation),
// `no_gate` (activation ignores the run; gateHeldAtActivation),
// `no_signer_check` (the author may sign off; signerIndependent) and
// `no_open_check` (sign-off with open findings; noOpenAtSignOff).

module release_impact {
  const RELEASES: Set[int]
  const USERS: Set[str]
  const MUTANT: str

  type RelSt = | NoRel | Received | Active | Superseded | Refused
  type RunSt = | NoRun | Running | Completed | SignedOff | Rejected | Stale

  var relSt: int -> RelSt
  var author: int -> str
  var needs: int -> bool            // the release changes figures (impact_required)
  var runSt: int -> RunSt
  var runBase: int -> int           // the active release when the run started (0: none)
  var openF: int -> int             // findings beyond tolerance not yet accepted
  var signer: int -> str
  var activeRel: int                // the active release (0: none)
  var clearedAtActivation: int -> bool   // ghost

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------

  // A run is current when nothing it was based on has moved since it started.
  def current(r: int): bool = runBase.get(r) == activeRel

  // What the gate asks (impact_cleared, spec 05): the release needs no run, or
  // its run has the status signed off. Currency is not asked: a stale run has
  // another status, which is the point of the controls below.
  def cleared(r: int): bool = not(needs.get(r)) or runSt.get(r) == SignedOff

  // What must be true at activation (ghost): and nothing moved under the run.
  def trulyCleared(r: int): bool =
    not(needs.get(r)) or (runSt.get(r) == SignedOff and current(r))

  def live(s: RunSt): bool = s == Running or s == Completed or s == SignedOff

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  action init = all {
    relSt' = RELEASES.mapBy(r => NoRel),
    author' = RELEASES.mapBy(r => ""),
    needs' = RELEASES.mapBy(r => false),
    runSt' = RELEASES.mapBy(r => NoRun),
    runBase' = RELEASES.mapBy(r => 0),
    openF' = RELEASES.mapBy(r => 0),
    signer' = RELEASES.mapBy(r => ""),
    activeRel' = 0,
    clearedAtActivation' = RELEASES.mapBy(r => false),
  }

  action keepRun = all {
    runSt' = runSt, runBase' = runBase,
    openF' = openF, signer' = signer,
  }
  action keepRel = all { relSt' = relSt, author' = author, needs' = needs }

  // A production release is received.
  action submit(r: int, a: str, n: bool): bool = all {
    relSt.get(r) == NoRel,
    relSt' = relSt.set(r, Received),
    author' = author.set(r, a),
    needs' = needs.set(r, n),
    keepRun, activeRel' = activeRel,
    clearedAtActivation' = clearedAtActivation,
  }

  // The run of a waiting release starts, or restarts after it went stale.
  // spec: 24-release-impact#StartImpactRun, 24-release-impact#RestartImpactRun
  action start(r: int): bool = all {
    relSt.get(r) == Received,
    needs.get(r),
    runSt.get(r) == NoRun or runSt.get(r) == Stale,
    runSt' = runSt.set(r, Running),
    runBase' = runBase.set(r, activeRel),
    openF' = openF, signer' = signer,
    keepRel, activeRel' = activeRel,
    clearedAtActivation' = clearedAtActivation,
  }

  // Every replay is fulfilled and compared: some findings are beyond tolerance.
  // spec: 24-release-impact#CompareFigures
  action complete(r: int, bad: int): bool = all {
    runSt.get(r) == Running,
    runSt' = runSt.set(r, Completed),
    openF' = openF.set(r, bad),
    runBase' = runBase, signer' = signer,
    keepRel, activeRel' = activeRel,
    clearedAtActivation' = clearedAtActivation,
  }

  // A reviewer other than the author accepts a finding.
  // spec: 24-release-impact#AcceptFinding
  action accept(r: int, v: str): bool = all {
    runSt.get(r) == Completed,
    openF.get(r) > 0,
    v != author.get(r),
    openF' = openF.set(r, openF.get(r) - 1),
    runSt' = runSt, runBase' = runBase, signer' = signer,
    keepRel, activeRel' = activeRel,
    clearedAtActivation' = clearedAtActivation,
  }

  // Sign-off: every finding closed, and a reviewer other than the author.
  // spec: 24-release-impact#SignOffImpact
  action signOff(r: int, v: str): bool = all {
    runSt.get(r) == Completed,
    MUTANT == "no_open_check" or openF.get(r) == 0,
    MUTANT == "no_signer_check" or v != author.get(r),
    runSt' = runSt.set(r, SignedOff),
    signer' = signer.set(r, v),
    runBase' = runBase, openF' = openF,
    keepRel, activeRel' = activeRel,
    clearedAtActivation' = clearedAtActivation,
  }

  // A run is rejected, or a replay fails: the release is refused with it.
  // spec: 24-release-impact#ReplayFails, 24-release-impact#RejectImpact
  // spec: 05-configuration-release#RefuseOnRejectedImpact
  action reject(r: int): bool = all {
    runSt.get(r) == Running or runSt.get(r) == Completed,
    runSt' = runSt.set(r, Rejected),
    relSt' = relSt.set(r, if (relSt.get(r) == Received) Refused else relSt.get(r)),
    author' = author, needs' = needs,
    runBase' = runBase, openF' = openF, signer' = signer,
    activeRel' = activeRel,
    clearedAtActivation' = clearedAtActivation,
  }

  // A release activates, superseding the previous one in the same step; the
  // runs of the other waiting releases were based on the old active release.
  // spec: 05-configuration-release#ActivateRelease, 05-configuration-release#ActivateScheduledRelease
  // spec: 05-configuration-release#ActivateAfterImpact, 24-release-impact#StaleOnBaseChange
  action activate(r: int): bool = all {
    relSt.get(r) == Received,
    MUTANT == "no_gate" or cleared(r),
    relSt' = RELEASES.mapBy(x =>
      if (x == r) Active
      else if (relSt.get(x) == Active) Superseded
      else relSt.get(x)),
    runSt' = RELEASES.mapBy(x =>
      if (MUTANT != "no_base_stale" and x != r and relSt.get(x) == Received and live(runSt.get(x)))
        Stale else runSt.get(x)),
    activeRel' = r,
    clearedAtActivation' = clearedAtActivation.set(r, trulyCleared(r)),
    author' = author, needs' = needs,
    runBase' = runBase, openF' = openF, signer' = signer,
  }

  action step = {
    nondet r = RELEASES.oneOf()
    nondet a = USERS.oneOf()
    nondet v = USERS.oneOf()
    nondet n = Set(true, false).oneOf()
    nondet bad = Set(0, 1, 2).oneOf()
    any {
      submit(r, a, n), start(r), complete(r, bad), accept(r, v), signOff(r, v),
      reject(r), activate(r),
    }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // The gate held at the instant of activation: the release needed no run, or
  // had a signed-off run that nothing had moved under since.
  val gateHeldAtActivation = RELEASES.forall(r =>
    if (relSt.get(r) == Active or relSt.get(r) == Superseded) clearedAtActivation.get(r)
    else true)

  // spec: 24-release-impact#SignerIsNotAuthor
  val signerIndependent = RELEASES.forall(r =>
    runSt.get(r) != SignedOff or signer.get(r) != author.get(r))

  // spec: 24-release-impact#SignedOffHasNoOpenFinding
  val noOpenAtSignOff = RELEASES.forall(r =>
    runSt.get(r) != SignedOff or openF.get(r) == 0)

  val oneActive = RELEASES.filter(r => relSt.get(r) == Active).size() <= 1

  val safety = and { gateHeldAtActivation, signerIndependent, noOpenAtSignOff, oneActive }

  // Witness, meant to be violated: a release that changes figures activates
  // after its impact run.
  val notActivatedAfterImpact =
    not(RELEASES.exists(r => needs.get(r) and relSt.get(r) == Active))
}

module impact {
  import release_impact(
    RELEASES = Set(1, 2),
    USERS = Set("alice", "bob", "carol"),
    MUTANT = ""
  ).*
}

module impact_mutant_no_base_stale {
  import release_impact(
    RELEASES = Set(1, 2),
    USERS = Set("alice", "bob", "carol"),
    MUTANT = "no_base_stale"
  ).*
}

module impact_mutant_no_gate {
  import release_impact(
    RELEASES = Set(1, 2),
    USERS = Set("alice", "bob", "carol"),
    MUTANT = "no_gate"
  ).*
}

module impact_mutant_no_signer_check {
  import release_impact(
    RELEASES = Set(1, 2),
    USERS = Set("alice", "bob", "carol"),
    MUTANT = "no_signer_check"
  ).*
}

module impact_mutant_no_open_check {
  import release_impact(
    RELEASES = Set(1, 2),
    USERS = Set("alice", "bob", "carol"),
    MUTANT = "no_open_check"
  ).*
}
