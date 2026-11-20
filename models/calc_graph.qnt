// -*- mode: Quint -*-
//
// The calculation graph against its ledger (spec 02): requests whose planned
// steps bind to shared, content-addressed nodes; stampede control; early
// cutoff; retries, rejection and ringfenced failure; payload ageing and
// rematerialisation; cancellation.
//
// What is modelled: several requests, each with two evaluation steps, A (its
// input) and B (which needs A's result). A node's calc_id is its identity: an
// A node's id is its input version; a B node's id is 100 + the result_hash of
// the A node, not the A node's id, which is the early-cutoff rule. Two inputs
// can have the same A result (RESULT), so their B steps meet in one node.
// Each action is one atomic ledger step (an unique calc_id and a conditional
// state change in one transaction), which is a requirement on the Elixir
// implementation.
//
// What is not modelled: planning and plan expansion (a request starts with its
// two steps), bitemporal resolution, data classes, queue capacity, wall-clock
// time (timeouts are crashes, ageing is nondeterministic), the worker protocol
// of spec 07 (see bundled_dispatch.qnt), payload references, attempt records and
// run environments (D-064), and inspection reruns (they use the same
// recomputation as a waiting step, without a step).
//
// Authority (D-055): this model is authoritative for the behaviour it covers.
//
// Split (D-065): the instances, including the negative controls, are in
// calc_graph_instances.qnt; the scenarios (quint test) are in
// calc_graph_scenarios.qnt. A late answer from a worker given up on is not
// modelled: the same hash is harmless and an answer for a payload that is no
// longer purged is dropped.

module calc_graph {
  const REQS: Set[int]
  const INPUT: int -> int          // input version (content hash) of each request
  const RESULT: int -> int         // result_hash of the A node, by input
  const MAX_ATTEMPTS: int
  const VARIANT: str               // "fixed", or the removed control: "mutant_no_stampede",
                                   // "mutant_dup_remat", "mutant_remat_broken",
                                   // "mutant_remat_lost"

  type ReqSt = | NoReq | Open | Fulfilled | Unfulfilled
  type StepSt = | NoStep | Waiting | Running | Done | Abandoned | Cancelled
  type NodeSt = | NoNode | Pending | Computing | Complete | Failed
  type Tier = | NoPayload | Hot | Cold | Purged

  val STEPS: Set[(int, int)] = REQS.map(r => (r, 0)).union(REQS.map(r => (r, 1)))
  val A_IDS: Set[int] = REQS.map(r => INPUT.get(r))
  val B_IDS: Set[int] = A_IDS.map(i => 100 + RESULT.get(i))
  val NODES: Set[int] = A_IDS.union(B_IDS)
  val ALL: Set[int] = NODES.union(Set(0))        // 0 stands for "no node"

  var reqSt: int -> ReqSt
  var stepSt: (int, int) -> StepSt
  var stepNode: (int, int) -> int
  var nodeSt: int -> NodeSt
  var attempts: int -> int
  var resultHash: int -> int
  var reproducible: int -> bool
  var tier: int -> Tier
  var rematInFlight: int -> int        // recomputations dispatched and not yet answered
  var inFlight: int -> int             // computations dispatched and not yet answered
  var created: int -> int              // ghost: nodes created per calc_id
  var badDone: bool                    // ghost: a step became done on an irreproducible node
  var memoHit: bool                    // ghost, for witnesses
  var attachedLive: bool
  var rematAttempts: int -> int        // dispatches of the current recomputation cycle (D-063)
  var rematLost: int -> bool           // ghost: a cycle for this node ran out of attempts
  var rematOk: bool
  var rematBad: bool                   // ghost: a recomputation was dispatched for an irreproducible node

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------

  // The deterministic result of computing a node.
  def computeResult(n: int): int = if (n < 100) RESULT.get(n) else n + 1000

  // calc_id of a step: A from its input, B from the result hash of A's node.
  def idOf(r: int, k: int): int =
    if (k == 0) INPUT.get(r) else 100 + resultHash.get(stepNode.get((r, 0)))

  def stepsDone(r: int): bool =
    stepSt.get((r, 0)) == Done and stepSt.get((r, 1)) == Done

  def anyAbandoned(r: int): bool =
    stepSt.get((r, 0)) == Abandoned or stepSt.get((r, 1)) == Abandoned

  // ------------------------------------------------------------
  // Frame helpers: one group of variables left unchanged
  // ------------------------------------------------------------

  action keepReq = reqSt' = reqSt
  action keepStep = all { stepSt' = stepSt, stepNode' = stepNode }
  action keepNode = all { nodeSt' = nodeSt, attempts' = attempts, resultHash' = resultHash }
  action keepPay = all { reproducible' = reproducible, tier' = tier }
  action keepRemat = all {
    rematInFlight' = rematInFlight, rematAttempts' = rematAttempts, rematLost' = rematLost,
  }
  action keepFly = inFlight' = inFlight
  action keepCreated = created' = created
  action keepFlags = all {
    badDone' = badDone, memoHit' = memoHit, attachedLive' = attachedLive,
    rematOk' = rematOk, rematBad' = rematBad,
  }

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  action init = all {
    reqSt' = REQS.mapBy(r => NoReq),
    stepSt' = STEPS.mapBy(s => NoStep),
    stepNode' = STEPS.mapBy(s => 0),
    nodeSt' = ALL.mapBy(n => NoNode),
    attempts' = ALL.mapBy(n => 0),
    resultHash' = ALL.mapBy(n => 0),
    reproducible' = ALL.mapBy(n => true),
    tier' = ALL.mapBy(n => NoPayload),
    rematInFlight' = ALL.mapBy(n => 0),
    rematAttempts' = ALL.mapBy(n => 0),
    rematLost' = ALL.mapBy(n => false),
    inFlight' = ALL.mapBy(n => 0),
    created' = ALL.mapBy(n => 0),
    badDone' = false,
    memoHit' = false,
    attachedLive' = false,
    rematOk' = false,
    rematBad' = false,
  }

  // A request is accepted with its two evaluation steps waiting.
  // spec: 02-calculation-graph#AcceptCalculationRequest
  action submit(r: int): bool = all {
    reqSt.get(r) == NoReq,
    reqSt' = reqSt.set(r, Open),
    stepSt' = stepSt.set((r, 0), Waiting).set((r, 1), Waiting),
    stepNode' = stepNode,
    keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // A ready step finds no node for its calc_id: exactly one new node is created.
  // spec: 02b-node-execution#StepBindsToNode
  action bindNew(r: int, k: int): bool = all {
    reqSt.get(r) == Open,
    stepSt.get((r, k)) == Waiting,
    (k == 0 or stepSt.get((r, 0)) == Done),
    nodeSt.get(idOf(r, k)) == NoNode,
    nodeSt' = nodeSt.set(idOf(r, k), Pending),
    attempts' = attempts.set(idOf(r, k), 0),
    resultHash' = resultHash,
    reproducible' = reproducible.set(idOf(r, k), true),
    tier' = tier,
    created' = created.set(idOf(r, k), created.get(idOf(r, k)) + 1),
    stepSt' = stepSt.set((r, k), Running),
    stepNode' = stepNode.set((r, k), idOf(r, k)),
    keepReq, keepRemat, keepFly, keepFlags,
  }

  // A ready step finds its node: memo hit, attach to an in-flight node,
  // rematerialise a purged payload, or inherit a failure. A node that is
  // irreproducible fails its steps at once, and a purged payload is recomputed
  // once however many steps wait for it (D-062).
  // spec: 02b-node-execution#StepBindsToNode, 02c-payload-retention#RematerialisationDispatched
  action bindExisting(r: int, k: int): bool = {
    val id = idOf(r, k)
    val ns = nodeSt.get(id)
    val dupOk = VARIANT == "mutant_dup_remat"          // removed control: one recomputation
    val brokenOk = VARIANT == "mutant_remat_broken"    // removed control: abandon at binding
    val purged = tier.get(id) == Purged
    val broken = not(reproducible.get(id))
    val failsAtBinding = broken and not(brokenOk)
    val wantsRemat = ns == Complete and purged and not(failsAtBinding)
    all {
      reqSt.get(r) == Open,
      stepSt.get((r, k)) == Waiting,
      (k == 0 or stepSt.get((r, 0)) == Done),
      ns != NoNode,
      stepNode' = stepNode.set((r, k), id),
      stepSt' = stepSt.set((r, k),
        if (ns == Complete)
          (if (failsAtBinding) Abandoned else if (purged) Running else Done)
        else if (ns == Failed) Abandoned
        else Running),
      rematInFlight' =
        if (wantsRemat)
          rematInFlight.set(id,
            if (dupOk) rematInFlight.get(id) + 1
            else (if (rematInFlight.get(id) == 0) 1 else rematInFlight.get(id)))
        else rematInFlight,
      // The first binding step starts a cycle: its first dispatch counts.
      rematAttempts' =
        if (wantsRemat and rematInFlight.get(id) == 0) rematAttempts.set(id, 1)
        else rematAttempts,
      rematLost' = rematLost,
      inFlight' =
        if (VARIANT == "mutant_no_stampede" and ns == Computing)
          inFlight.set(id, inFlight.get(id) + 1)
        else inFlight,
      memoHit' = (memoHit or (ns == Complete and not(purged) and not(broken))),
      attachedLive' = (attachedLive or ns == Computing),
      badDone' = (badDone or (ns == Complete and not(purged) and broken and brokenOk)),
      rematBad' = (rematBad or (wantsRemat and broken)),
      rematOk' = rematOk,
      keepReq, keepNode, keepPay, keepCreated,
    }
  }

  // spec: 02b-node-execution#DispatchNode
  action dispatch(n: int): bool = all {
    nodeSt.get(n) == Pending,
    attempts.get(n) < MAX_ATTEMPTS,
    nodeSt' = nodeSt.set(n, Computing),
    attempts' = attempts.set(n, attempts.get(n) + 1),
    resultHash' = resultHash,
    inFlight' = inFlight.set(n, inFlight.get(n) + 1),
    keepReq, keepStep, keepPay, keepRemat, keepCreated, keepFlags,
  }

  // spec: 02b-node-execution#ComputationSucceeds
  action succeed(n: int): bool = all {
    nodeSt.get(n) == Computing,
    nodeSt' = nodeSt.set(n, Complete),
    resultHash' = resultHash.set(n, computeResult(n)),
    attempts' = attempts,
    tier' = tier.set(n, Hot),
    reproducible' = reproducible,
    inFlight' = inFlight.set(n, 0),
    keepReq, keepStep, keepRemat, keepCreated, keepFlags,
  }

  // Infrastructure failure, including a timeout: retry while attempts remain.
  // spec: 02b-node-execution#ComputationCrashes, 02b-node-execution#ComputationTimesOut
  action crash(n: int): bool = all {
    nodeSt.get(n) == Computing,
    nodeSt' = nodeSt.set(n, if (attempts.get(n) < MAX_ATTEMPTS) Pending else Failed),
    attempts' = attempts,
    resultHash' = resultHash,
    inFlight' = inFlight.set(n, 0),
    keepReq, keepStep, keepPay, keepRemat, keepCreated, keepFlags,
  }

  // Deterministic rejection: terminal at once.
  // spec: 02b-node-execution#ComputationRejects
  action reject(n: int): bool = all {
    nodeSt.get(n) == Computing,
    nodeSt' = nodeSt.set(n, Failed),
    attempts' = attempts,
    resultHash' = resultHash,
    inFlight' = inFlight.set(n, 0),
    keepReq, keepStep, keepPay, keepRemat, keepCreated, keepFlags,
  }

  // spec: 02c-payload-retention#PayloadMovesToColdStorage
  action cool(n: int): bool = all {
    nodeSt.get(n) == Complete,
    tier.get(n) == Hot,
    tier' = tier.set(n, Cold),
    reproducible' = reproducible,
    keepReq, keepStep, keepNode, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // A payload is not purged under a step still running on its node (D-063).
  // spec: 02c-payload-retention#PayloadPurged
  action purge(n: int): bool = all {
    nodeSt.get(n) == Complete,
    tier.get(n) == Cold,
    not(STEPS.exists(s => stepSt.get(s) == Running and stepNode.get(s) == n)),
    tier' = tier.set(n, Purged),
    reproducible' = reproducible,
    keepReq, keepStep, keepNode, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // The answer of a recomputation: the same hash restores the payload; a
  // different one marks the node irreproducible. An answer for a payload that
  // is no longer purged is dropped.
  // spec: 02c-payload-retention#RematerialisationSucceeds, 02c-payload-retention#MarkNodeIrreproducible
  action rematAnswer(n: int, same: bool): bool = all {
    rematInFlight.get(n) > 0,
    rematInFlight' = rematInFlight.set(n, rematInFlight.get(n) - 1),
    rematAttempts' = rematAttempts.set(n, 0),
    rematLost' = rematLost,
    tier' = if (tier.get(n) == Purged and same) tier.set(n, Hot) else tier,
    reproducible' =
      if (tier.get(n) == Purged and not(same)) reproducible.set(n, false) else reproducible,
    rematOk' = (rematOk or (tier.get(n) == Purged and same)),
    badDone' = badDone, memoHit' = memoHit, attachedLive' = attachedLive,
    rematBad' = rematBad,
    keepReq, keepStep, keepNode, keepFly, keepCreated,
  }

  // A recomputation is lost (crash, lost host or timeout). While attempts
  // remain it is dispatched again. When they run out the cycle ends: the steps
  // waiting for the payload are abandoned, and the node stays reproducible; a
  // later binding step starts a fresh cycle (D-063). The mutant
  // `remat_lost` only drops the in-flight count and leaves the steps running.
  // spec: 02c-payload-retention#RecomputationCrashes, 02c-payload-retention#RecomputationTimesOut
  action rematCrash(n: int): bool = {
    val retry = VARIANT != "mutant_remat_lost" and rematAttempts.get(n) < MAX_ATTEMPTS
    val strand = VARIANT == "mutant_remat_lost"
    all {
      rematInFlight.get(n) > 0,
      tier.get(n) == Purged,
      rematAttempts' = if (retry) rematAttempts.set(n, rematAttempts.get(n) + 1) else rematAttempts.set(n, 0),
      rematInFlight' = if (retry) rematInFlight else rematInFlight.set(n, rematInFlight.get(n) - 1),
      rematLost' = if (retry or strand) rematLost else rematLost.set(n, true),
      stepSt' =
        if (retry or strand) stepSt
        else STEPS.mapBy(s =>
          if (stepSt.get(s) == Running and stepNode.get(s) == n) Abandoned else stepSt.get(s)),
      stepNode' = stepNode,
      keepReq, keepNode, keepPay, keepFly, keepCreated, keepFlags,
    }
  }

  // An inspector reruns a purged payload: a cycle with no step waiting (D-064).
  // spec: 02d-attempts-and-inspection#RerunRequested
  action rerun(n: int): bool = all {
    nodeSt.get(n) == Complete, tier.get(n) == Purged, reproducible.get(n),
    rematInFlight.get(n) == 0,
    rematInFlight' = rematInFlight.set(n, 1),
    rematAttempts' = rematAttempts.set(n, 1),
    rematLost' = rematLost,
    keepReq, keepStep, keepNode, keepPay, keepFly, keepCreated, keepFlags,
  }

  // A running step ends with its node: done when the result is available,
  // abandoned when the node failed or is irreproducible.
  // spec: 02b-node-execution#StepCompletesWithNode
  action stepDone(r: int, k: int): bool = all {
    stepSt.get((r, k)) == Running,
    nodeSt.get(stepNode.get((r, k))) == Complete,
    reproducible.get(stepNode.get((r, k))),
    (tier.get(stepNode.get((r, k))) == Hot or tier.get(stepNode.get((r, k))) == Cold),
    stepSt' = stepSt.set((r, k), Done),
    stepNode' = stepNode,
    keepReq, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02b-node-execution#StepFailsWithNode
  action stepAbandon(r: int, k: int): bool = all {
    stepSt.get((r, k)) == Running,
    (nodeSt.get(stepNode.get((r, k))) == Failed
      or not(reproducible.get(stepNode.get((r, k))))),
    stepSt' = stepSt.set((r, k), Abandoned),
    stepNode' = stepNode,
    keepReq, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02b-node-execution#RequestCompletes
  action requestFulfil(r: int): bool = all {
    reqSt.get(r) == Open,
    stepsDone(r),
    reqSt' = reqSt.set(r, Fulfilled),
    keepStep, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02b-node-execution#RequestFails
  action requestFail(r: int): bool = all {
    reqSt.get(r) == Open,
    anyAbandoned(r),
    reqSt' = reqSt.set(r, Unfulfilled),
    keepStep, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02b-node-execution#CancelRequest
  action cancel(r: int): bool = all {
    reqSt.get(r) == Open,
    reqSt' = reqSt.set(r, Unfulfilled),
    keepStep, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // Waiting steps of a failed request are cancelled; running ones keep going.
  // spec: 02b-node-execution#StepCancelledWithRequest
  action stepCancel(r: int, k: int): bool = all {
    reqSt.get(r) == Unfulfilled,
    stepSt.get((r, k)) == Waiting,
    stepSt' = stepSt.set((r, k), Cancelled),
    stepNode' = stepNode,
    keepReq, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  action step = {
    nondet r = REQS.oneOf()
    nondet k = Set(0, 1).oneOf()
    nondet n = NODES.oneOf()
    nondet same = Set(true, false).oneOf()
    any {
      submit(r),
      bindNew(r, k),
      bindExisting(r, k),
      dispatch(n),
      succeed(n),
      crash(n),
      reject(n),
      cool(n),
      purge(n),
      rematAnswer(n, same),
      rematCrash(n),
      rerun(n),
      stepDone(r, k),
      stepAbandon(r, k),
      requestFulfil(r),
      requestFail(r),
      cancel(r),
      stepCancel(r, k),
    }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // spec: 02b-node-execution#AttemptsBounded
  val attemptsBounded = NODES.forall(n => attempts.get(n) <= MAX_ATTEMPTS)

  // One node per calc_id, however many steps and requests meet in it.
  // spec: 02b-node-execution#OneNodePerCalcId
  val oneNodePerCalcId = NODES.forall(n => created.get(n) <= 1)

  // Stampede control: a node is computed by one dispatch at a time.
  val oneInFlight = NODES.forall(n => inFlight.get(n) <= 1)

  // A purged payload is recomputed once, however many steps wait for it.
  // spec: 02c-payload-retention#RematerialisationDispatched
  val oneRematInFlight = NODES.forall(n => rematInFlight.get(n) <= 1)

  // No recomputation is dispatched for a node already known irreproducible.
  // spec: 02c-payload-retention#NoRecomputationOfIrreproducibleNode
  val noRematOnBroken = not(rematBad)

  // A step is never done on an irreproducible node, and a done step has a
  // complete node.
  val doneIsSound = and {
    not(badDone),
    STEPS.forall(s =>
      stepSt.get(s) != Done or nodeSt.get(stepNode.get(s)) == Complete),
  }

  // Ringfence: a step is abandoned only because its own node failed or is
  // irreproducible, or because a recomputation of its payload ran out of
  // attempts (D-063).
  val abandonedHasCause = STEPS.forall(s =>
    stepSt.get(s) != Abandoned
      or (nodeSt.get(stepNode.get(s)) == Failed
          or not(reproducible.get(stepNode.get(s)))
          or rematLost.get(stepNode.get(s))))

  // A step waiting on a purged payload always has a recomputation in flight
  // (D-063): a lost one is retried or ends the step, never leaves it waiting.
  // spec: 02c-payload-retention#RecomputationCrashes
  val purgedWaiterHasRemat = STEPS.forall(s =>
    not(stepSt.get(s) == Running
        and nodeSt.get(stepNode.get(s)) == Complete
        and tier.get(stepNode.get(s)) == Purged
        and reproducible.get(stepNode.get(s)))
      or rematInFlight.get(stepNode.get(s)) > 0)

  val requestStatesAgree = and {
    REQS.forall(r => reqSt.get(r) != Fulfilled or stepsDone(r)),
    STEPS.forall(s => stepSt.get(s) != Cancelled or reqSt.get(s._1) == Unfulfilled),
  }

  // The shape of a node's record, enforced again by the ledger's database
  // constraints result_iff_complete and complete_is_whole (D-080): a node has a
  // result exactly when it is complete, and a complete node has a payload tier.
  val resultIffComplete = NODES.forall(n =>
    and {
      (nodeSt.get(n) == Complete) == (resultHash.get(n) != 0),
      nodeSt.get(n) != Complete or tier.get(n) != NoPayload,
    })

  // Counters never go below zero (database constraint counters_not_negative).
  val countersNotNegative = NODES.forall(n =>
    and { attempts.get(n) >= 0, rematInFlight.get(n) >= 0, rematAttempts.get(n) >= 0 })

  val safety = and {
    attemptsBounded, oneNodePerCalcId, oneInFlight, oneRematInFlight,
    noRematOnBroken, doneIsSound, abandonedHasCause, purgedWaiterHasRemat,
    requestStatesAgree, resultIffComplete, countersNotNegative,
  }

  // ------------------------------------------------------------
  // Witnesses: expected to be violated, which shows the behaviour is reachable
  // ------------------------------------------------------------

  val notFulfilled = not(REQS.exists(r => reqSt.get(r) == Fulfilled))
  val notUnfulfilled = not(REQS.exists(r => reqSt.get(r) == Unfulfilled))
  val notMemoHit = not(memoHit)
  val notAttached = not(attachedLive)
  val notRematerialised = not(rematOk)
  val notRetried = not(NODES.exists(n => attempts.get(n) >= 2 and nodeSt.get(n) == Complete))
  val notFailedNode = not(NODES.exists(n => nodeSt.get(n) == Failed))
  // Early cutoff: steps of two requests with different inputs share a B node.
  val notEarlyCutoff = not(REQS.exists(r1 => REQS.exists(r2 =>
    r1 != r2
    and INPUT.get(r1) != INPUT.get(r2)
    and stepNode.get((r1, 1)) != 0
    and stepNode.get((r1, 1)) == stepNode.get((r2, 1)))))
}
