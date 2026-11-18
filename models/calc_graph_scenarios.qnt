// -*- mode: Quint -*-
//
// Scenarios (quint test) and instances of the calculation-graph model
// (calc_graph.qnt, spec 02). Random simulation does not reach the deeper
// sequences, so each finding is replayed step by step. Instance: three
// requests, A ids 1 and 2, both with result hash 7, so one shared B node 107.
// The scenarios run against the behaviour and against each negative control
// (VARIANT); the gate says which control must fail which scenario.

module calc_graph_scenarios {
  const WHICH: str
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = WHICH
  ).* from "./calc_graph"

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

  // A recomputation is lost twice (MAX_ATTEMPTS = 2): the first loss is retried,
  // the second ends the cycle and abandons the waiting step; the node stays
  // reproducible, and a later step starts a fresh cycle that succeeds (D-063).
  run lostRematTest =
    firstRequest
      .then(cool(107)).then(purge(107))
      .then(bindNew(2, 0)).then(dispatch(2)).then(succeed(2)).then(stepDone(2, 0))
      .then(bindExisting(2, 1))
      .then(rematCrash(107))
      .then(all {
        assert(rematInFlight.get(107) == 1 and rematAttempts.get(107) == 2
          and stepSt.get((2, 1)) == Running),
        unchangedAll,
      })
      .then(rematCrash(107))
      .then(all {
        assert(rematInFlight.get(107) == 0 and stepSt.get((2, 1)) == Abandoned
          and reproducible.get(107) and tier.get(107) == Purged
          and nodeSt.get(107) == Complete and purgedWaiterHasRemat),
        unchangedAll,
      })
      .then(bindExisting(3, 0)).then(bindExisting(3, 1))
      .then(all {
        assert(rematInFlight.get(107) == 1 and rematAttempts.get(107) == 1
          and stepSt.get((3, 1)) == Running),
        unchangedAll,
      })
      .then(rematAnswer(107, true)).then(stepDone(3, 1))
      .then(all {
        assert(stepSt.get((3, 1)) == Done and tier.get(107) == Hot and safety),
        unchangedAll,
      })

  // One loss: the waiting step must still have a recomputation in flight. The
  // mutant `remat_lost` drops the count and leaves the step running, so it
  // violates purgedWaiterHasRemat here and must fail this (D-063).
  run lostRematWaiterTest =
    firstRequest
      .then(cool(107)).then(purge(107))
      .then(bindNew(2, 0)).then(dispatch(2)).then(succeed(2)).then(stepDone(2, 0))
      .then(bindExisting(2, 1))
      .then(rematCrash(107))
      .then(all { assert(purgedWaiterHasRemat), unchangedAll })

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
        assert(nodeSt.get(1) == Failed and attempts.get(1) == 2),
        unchangedAll,
      })
}

module calc_graph_fixed {
  import calc_graph_scenarios(WHICH = "fixed").*
}

module calc_graph_mutant_no_stampede {
  import calc_graph_scenarios(WHICH = "mutant_no_stampede").*
}

module calc_graph_mutant_dup_remat {
  import calc_graph_scenarios(WHICH = "mutant_dup_remat").*
}

module calc_graph_mutant_remat_broken {
  import calc_graph_scenarios(WHICH = "mutant_remat_broken").*
}

module calc_graph_mutant_remat_lost {
  import calc_graph_scenarios(WHICH = "mutant_remat_lost").*
}
