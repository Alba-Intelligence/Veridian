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
// of spec 07 (see bundled_dispatch.qnt), payload references.
//
// Authority (D-055): this model is authoritative for the behaviour it covers.
//
// Instances. `calc_graph_fixed` is the behaviour (D-062: one recomputation per
// purged payload, and a step bound to an irreproducible node is abandoned at
// binding). The `calc_graph_mutant_*` instances are negative controls, not
// behaviour: each removes one control and the gate requires it to violate the
// matching property or scenario, so the properties are known to have teeth:
// `no_stampede` (oneInFlight), `dup_remat` (spec 02 as written before D-062:
// every binding step dispatches its own recomputation; oneRematInFlight) and
// `remat_broken` (as written before D-062: a recomputation is dispatched for an
// irreproducible node; noRematOnBroken).

module calc_graph {
  const REQS: Set[int]
  const INPUT: int -> int          // input version (content hash) of each request
  const RESULT: int -> int         // result_hash of the A node, by input
  const MAX_ATTEMPTS: int
  const VARIANT: str               // "fixed", or the removed control: "mutant_no_stampede",
                                   // "mutant_dup_remat", "mutant_remat_broken"

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
  action keepRemat = rematInFlight' = rematInFlight
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
  // spec: 02-calculation-graph#StepBindsToNode
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
  // spec: 02-calculation-graph#StepBindsToNode, 02-calculation-graph#RematerialisationDispatched
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

  // spec: 02-calculation-graph#DispatchNode
  action dispatch(n: int): bool = all {
    nodeSt.get(n) == Pending,
    attempts.get(n) < MAX_ATTEMPTS,
    nodeSt' = nodeSt.set(n, Computing),
    attempts' = attempts.set(n, attempts.get(n) + 1),
    resultHash' = resultHash,
    inFlight' = inFlight.set(n, inFlight.get(n) + 1),
    keepReq, keepStep, keepPay, keepRemat, keepCreated, keepFlags,
  }

  // spec: 02-calculation-graph#ComputationSucceeds
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
  // spec: 02-calculation-graph#ComputationCrashes, 02-calculation-graph#ComputationTimesOut
  action crash(n: int): bool = all {
    nodeSt.get(n) == Computing,
    nodeSt' = nodeSt.set(n, if (attempts.get(n) < MAX_ATTEMPTS) Pending else Failed),
    attempts' = attempts,
    resultHash' = resultHash,
    inFlight' = inFlight.set(n, 0),
    keepReq, keepStep, keepPay, keepRemat, keepCreated, keepFlags,
  }

  // Deterministic rejection: terminal at once.
  // spec: 02-calculation-graph#ComputationRejects
  action reject(n: int): bool = all {
    nodeSt.get(n) == Computing,
    nodeSt' = nodeSt.set(n, Failed),
    attempts' = attempts,
    resultHash' = resultHash,
    inFlight' = inFlight.set(n, 0),
    keepReq, keepStep, keepPay, keepRemat, keepCreated, keepFlags,
  }

  // spec: 02-calculation-graph#PayloadMovesToColdStorage
  action cool(n: int): bool = all {
    nodeSt.get(n) == Complete,
    tier.get(n) == Hot,
    tier' = tier.set(n, Cold),
    reproducible' = reproducible,
    keepReq, keepStep, keepNode, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02-calculation-graph#PayloadPurged
  action purge(n: int): bool = all {
    nodeSt.get(n) == Complete,
    tier.get(n) == Cold,
    tier' = tier.set(n, Purged),
    reproducible' = reproducible,
    keepReq, keepStep, keepNode, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // The answer of a recomputation: the same hash restores the payload; a
  // different one marks the node irreproducible. An answer for a payload that
  // is no longer purged is dropped.
  // spec: 02-calculation-graph#RematerialisationSucceeds, 02-calculation-graph#MarkNodeIrreproducible
  action rematAnswer(n: int, same: bool): bool = all {
    rematInFlight.get(n) > 0,
    rematInFlight' = rematInFlight.set(n, rematInFlight.get(n) - 1),
    tier' = if (tier.get(n) == Purged and same) tier.set(n, Hot) else tier,
    reproducible' =
      if (tier.get(n) == Purged and not(same)) reproducible.set(n, false) else reproducible,
    rematOk' = (rematOk or (tier.get(n) == Purged and same)),
    badDone' = badDone, memoHit' = memoHit, attachedLive' = attachedLive,
    rematBad' = rematBad,
    keepReq, keepStep, keepNode, keepFly, keepCreated,
  }

  // A running step ends with its node: done when the result is available,
  // abandoned when the node failed or is irreproducible.
  // spec: 02-calculation-graph#StepCompletesWithNode
  action stepDone(r: int, k: int): bool = all {
    stepSt.get((r, k)) == Running,
    nodeSt.get(stepNode.get((r, k))) == Complete,
    reproducible.get(stepNode.get((r, k))),
    (tier.get(stepNode.get((r, k))) == Hot or tier.get(stepNode.get((r, k))) == Cold),
    stepSt' = stepSt.set((r, k), Done),
    stepNode' = stepNode,
    keepReq, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02-calculation-graph#StepFailsWithNode
  action stepAbandon(r: int, k: int): bool = all {
    stepSt.get((r, k)) == Running,
    (nodeSt.get(stepNode.get((r, k))) == Failed
      or not(reproducible.get(stepNode.get((r, k))))),
    stepSt' = stepSt.set((r, k), Abandoned),
    stepNode' = stepNode,
    keepReq, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02-calculation-graph#RequestCompletes
  action requestFulfil(r: int): bool = all {
    reqSt.get(r) == Open,
    stepsDone(r),
    reqSt' = reqSt.set(r, Fulfilled),
    keepStep, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02-calculation-graph#RequestFails
  action requestFail(r: int): bool = all {
    reqSt.get(r) == Open,
    anyAbandoned(r),
    reqSt' = reqSt.set(r, Unfulfilled),
    keepStep, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // spec: 02-calculation-graph#CancelRequest
  action cancel(r: int): bool = all {
    reqSt.get(r) == Open,
    reqSt' = reqSt.set(r, Unfulfilled),
    keepStep, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // Waiting steps of a failed request are cancelled; running ones keep going.
  // spec: 02-calculation-graph#StepCancelledWithRequest
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

  // spec: 02-calculation-graph#AttemptsBounded
  val attemptsBounded = NODES.forall(n => attempts.get(n) <= MAX_ATTEMPTS)

  // One node per calc_id, however many steps and requests meet in it.
  // spec: 02-calculation-graph#OneNodePerCalcId
  val oneNodePerCalcId = NODES.forall(n => created.get(n) <= 1)

  // Stampede control: a node is computed by one dispatch at a time.
  val oneInFlight = NODES.forall(n => inFlight.get(n) <= 1)

  // A purged payload is recomputed once, however many steps wait for it.
  // spec: 02-calculation-graph#RematerialisationDispatched
  val oneRematInFlight = NODES.forall(n => rematInFlight.get(n) <= 1)

  // No recomputation is dispatched for a node already known irreproducible.
  // spec: 02-calculation-graph#NoRecomputationOfIrreproducibleNode
  val noRematOnBroken = not(rematBad)

  // A step is never done on an irreproducible node, and a done step has a
  // complete node.
  val doneIsSound = and {
    not(badDone),
    STEPS.forall(s =>
      stepSt.get(s) != Done or nodeSt.get(stepNode.get(s)) == Complete),
  }

  // Ringfence: a step is abandoned only because its own node failed or is
  // irreproducible.
  val abandonedHasCause = STEPS.forall(s =>
    stepSt.get(s) != Abandoned
      or (nodeSt.get(stepNode.get(s)) == Failed
          or not(reproducible.get(stepNode.get(s)))))

  val requestStatesAgree = and {
    REQS.forall(r => reqSt.get(r) != Fulfilled or stepsDone(r)),
    STEPS.forall(s => stepSt.get(s) != Cancelled or reqSt.get(s._1) == Unfulfilled),
  }

  val safety = and {
    attemptsBounded, oneNodePerCalcId, oneInFlight, oneRematInFlight,
    noRematOnBroken, doneIsSound, abandonedHasCause, requestStatesAgree,
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

  // ------------------------------------------------------------
  // Scenarios (quint test). Random simulation does not reach the deeper
  // sequences, so each finding is replayed step by step. Instance used: three
  // requests, A ids 1 and 2, both with result hash 7, so one shared B node 107.
  // ------------------------------------------------------------

  action unchangedAll = all {
    keepReq, keepStep, keepNode, keepPay, keepRemat, keepFly, keepCreated, keepFlags,
  }

  // Request 1 runs to completion: its A node 1 and the shared B node 107.
  run firstRequest =
    init
      .then(submit(1)).then(submit(2)).then(submit(3))
      .then(bindNew(1, 0)).then(dispatch(1)).then(succeed(1)).then(stepDone(1, 0))
      .then(bindNew(1, 1)).then(dispatch(107)).then(succeed(107)).then(stepDone(1, 1))
      .then(requestFulfil(1))

  // Early cutoff: request 2 has another input but the same A result, so its B
  // step lands on node 107 (one node created) and is a memo hit.
  run earlyCutoffTest =
    firstRequest
      .then(bindNew(2, 0)).then(dispatch(2)).then(succeed(2)).then(stepDone(2, 0))
      .then(bindExisting(2, 1))
      .then(all {
        assert(not(notEarlyCutoff) and created.get(107) == 1 and created.get(2) == 1
          and stepSt.get((2, 1)) == Done),
        unchangedAll,
      })

  // Two steps wait for the same purged payload: one recomputation (D-062). The
  // mutant `dup_remat` dispatches one per binding step and must fail this.
  run purgedTwiceTest =
    firstRequest
      .then(cool(107)).then(purge(107))
      .then(bindNew(2, 0)).then(dispatch(2)).then(succeed(2)).then(stepDone(2, 0))
      .then(bindExisting(2, 1))
      .then(bindExisting(3, 0)).then(bindExisting(3, 1))
      .then(all {
        assert(rematInFlight.get(107) == 1 and oneRematInFlight),
        unchangedAll,
      })

  // A recomputation disagrees, the node is irreproducible, and a later step
  // binds to it: the step is abandoned at once and nothing is dispatched
  // (D-062). The mutant `remat_broken` dispatches another recomputation and
  // must fail this.
  run brokenNodeTest =
    firstRequest
      .then(cool(107)).then(purge(107))
      .then(bindNew(2, 0)).then(dispatch(2)).then(succeed(2)).then(stepDone(2, 0))
      .then(bindExisting(2, 1))
      .then(rematAnswer(107, false))
      .then(bindExisting(3, 0)).then(bindExisting(3, 1))
      .then(all {
        assert(not(reproducible.get(107)) and noRematOnBroken
          and stepSt.get((3, 1)) == Abandoned),
        unchangedAll,
      })

  // A rejected node fails only the steps bound to it; the sibling request on
  // another input is unaffected, and a failed request cancels its waiting step.
  run ringfenceTest =
    init
      .then(submit(1)).then(submit(2))
      .then(bindNew(1, 0)).then(dispatch(1)).then(reject(1))
      .then(stepAbandon(1, 0)).then(requestFail(1)).then(stepCancel(1, 1))
      .then(bindNew(2, 0)).then(dispatch(2)).then(succeed(2)).then(stepDone(2, 0))
      .then(all {
        assert(stepSt.get((1, 0)) == Abandoned and stepSt.get((1, 1)) == Cancelled
          and reqSt.get(1) == Unfulfilled and stepSt.get((2, 0)) == Done
          and reqSt.get(2) == Open),
        unchangedAll,
      })

  // Retry: a crash returns the node to pending while attempts remain; at the
  // limit the node fails.
  run retryTest =
    init
      .then(submit(1)).then(bindNew(1, 0))
      .then(dispatch(1)).then(crash(1)).then(dispatch(1)).then(crash(1))
      .then(all {
        assert(nodeSt.get(1) == Failed and attempts.get(1) == MAX_ATTEMPTS),
        unchangedAll,
      })
}

// Three requests: 1 and 3 share an input (memo, stampede); 1 and 2 differ in
// input but their A results are equal (early cutoff, one shared B node).
module calc_graph_fixed {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "fixed"
  ).*
}

module calc_graph_mutant_dup_remat {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "mutant_dup_remat"
  ).*
}

module calc_graph_mutant_remat_broken {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "mutant_remat_broken"
  ).*
}

module calc_graph_mutant_no_stampede {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "mutant_no_stampede"
  ).*
}
