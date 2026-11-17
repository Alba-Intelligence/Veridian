// -*- mode: Quint -*-
//
// Bundled dispatch of spec 07 (D-044, D-045) as a transition system.
//
// What is modelled: nodes (one calculation per position), the control plane's
// tickets and its view of each worker, the worker processes, reports in
// flight, heartbeat-based loss declaration (including a false timeout: the
// process is alive but declared lost), process death, and one ledger
// transaction per bundle.
//
// What is not modelled: priorities beyond "lowest id first", build
// compatibility, memo hits, time, backpressure, host presence, recycling.
//
// Two instances at the bottom. `dispatch` is the behaviour of spec 07 (D-056):
// when a worker is declared lost, its held tickets and its reported but
// uncommitted tickets return to the queue. `dispatch_mutant_no_reap` switches
// the second part off. It is NOT behaviour of the system: it is a negative
// control, kept so that the gate can show that `noOrphanedReport` still
// detects the stranded-report bug the first version of the spec had.

module bundled_dispatch {
  const NODES: Set[int]
  const WORKERS: Set[str]
  const BUNDLE: int                 // config.bundle_size
  const MAX_ATTEMPTS: int           // crashes a node may take before it fails
  const REAP_UNCOMMITTED: bool      // true in the system; false only in the mutant
  const MAX_FAULTS: int             // process deaths plus loss declarations per run

  type NodeSt = | Queued | Assigned | Reported | Complete | Failed
  type Life = | Idle | Busy | Stopped

  // Control plane.
  var nodeSt: int -> NodeSt
  var nodeWorker: int -> str        // "" when none
  var attempts: int -> int
  var life: str -> Life             // WorkerProcess.lifecycle
  var cpLive: str -> bool           // false once the host is declared lost
  var commits: int -> int           // ledger commits per node
  var everComplete: Set[int]

  // Worker side and the wire.
  var procAlive: str -> bool
  var wHeld: str -> Set[int]        // bundle the process still has to run
  var inflight: Set[(str, int)]     // results sent, not yet received

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------

  def assignedTo(w: str): Set[int] =
    NODES.filter(n => nodeSt.get(n) == Assigned and nodeWorker.get(n) == w)

  def reportedBy(w: str): Set[int] =
    NODES.filter(n => nodeSt.get(n) == Reported and nodeWorker.get(n) == w)

  // Faults so far, derived from the state: dead processes plus hosts declared
  // lost. Bounding them keeps random runs long enough to make progress.
  def faultCount: int =
    WORKERS.filter(w => not(procAlive.get(w))).size() +
    WORKERS.filter(w => not(cpLive.get(w))).size()

  // Nodes returned to the queue when w is declared lost.
  def hit(w: str, n: int): bool =
    nodeWorker.get(n) == w and
    (nodeSt.get(n) == Assigned or (REAP_UNCOMMITTED and nodeSt.get(n) == Reported))

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  action init = all {
    nodeSt' = NODES.mapBy(n => Queued),
    nodeWorker' = NODES.mapBy(n => ""),
    attempts' = NODES.mapBy(n => 0),
    life' = WORKERS.mapBy(w => Idle),
    cpLive' = WORKERS.mapBy(w => true),
    commits' = NODES.mapBy(n => 0),
    everComplete' = Set(),
    procAlive' = WORKERS.mapBy(w => true),
    wHeld' = WORKERS.mapBy(w => Set()),
    inflight' = Set(),
  }

  // AssignJob: an idle worker takes up to BUNDLE queued nodes, lowest id first.
  // spec: 07-julia-workers#AssignJob, 07-julia-workers#BundledDispatch
  action takeBundle(w: str): bool = {
    val queued = NODES.filter(n => nodeSt.get(n) == Queued)
    val take = queued.filter(n => queued.filter(m => m < n).size() < BUNDLE)
    all {
      cpLive.get(w),
      life.get(w) == Idle,
      take.size() > 0,
      life' = life.set(w, Busy),
      nodeSt' = NODES.mapBy(n => if (take.contains(n)) Assigned else nodeSt.get(n)),
      nodeWorker' = NODES.mapBy(n => if (take.contains(n)) w else nodeWorker.get(n)),
      wHeld' = wHeld.set(w, take),
      attempts' = attempts, cpLive' = cpLive, commits' = commits,
      everComplete' = everComplete, procAlive' = procAlive, inflight' = inflight,
    }
  }

  // The worker process finishes one node of its bundle and sends the result.
  action workerFinishes(w: str, n: int): bool = all {
    procAlive.get(w),
    wHeld.get(w).contains(n),
    wHeld' = wHeld.set(w, wHeld.get(w).exclude(Set(n))),
    inflight' = inflight.union(Set((w, n))),
    nodeSt' = nodeSt, nodeWorker' = nodeWorker, attempts' = attempts,
    life' = life, cpLive' = cpLive, commits' = commits,
    everComplete' = everComplete, procAlive' = procAlive,
  }

  // The control plane receives a result. A result from a worker declared lost,
  // or for a ticket it no longer holds, is ignored (LivenessFromHeartbeat).
  // spec: 07-julia-workers#JobSucceeds, 07-julia-workers#LivenessFromHeartbeat
  action receive(w: str, n: int): bool = all {
    inflight.contains((w, n)),
    inflight' = inflight.exclude(Set((w, n))),
    nodeSt' = if (cpLive.get(w) and nodeSt.get(n) == Assigned and nodeWorker.get(n) == w)
                nodeSt.set(n, Reported)
              else nodeSt,
    nodeWorker' = nodeWorker, attempts' = attempts, life' = life,
    cpLive' = cpLive, commits' = commits, everComplete' = everComplete,
    procAlive' = procAlive, wHeld' = wHeld,
  }

  // BatchedLedgerWrite: once every ticket of the bundle is reported, the
  // completions are recorded in one transaction; the worker is then free.
  // spec: 07-julia-workers#BatchedLedgerWrite, 07-julia-workers#BundleFinished
  // spec: 07-julia-workers#BundleCommitted
  action commitBundle(w: str): bool = {
    val batch = reportedBy(w)
    all {
      cpLive.get(w),
      life.get(w) == Busy,
      assignedTo(w).size() == 0,
      batch.size() > 0,
      nodeSt' = NODES.mapBy(n => if (batch.contains(n)) Complete else nodeSt.get(n)),
      commits' = NODES.mapBy(n => if (batch.contains(n)) commits.get(n) + 1 else commits.get(n)),
      everComplete' = everComplete.union(batch),
      life' = life.set(w, Idle),
      nodeWorker' = nodeWorker, attempts' = attempts, cpLive' = cpLive,
      procAlive' = procAlive, wHeld' = wHeld, inflight' = inflight,
    }
  }

  // The worker process exits (crash, out-of-memory kill). Results already sent
  // stay in flight.
  // spec: 07-julia-workers#WorkerExitReported
  action procDies(w: str): bool = all {
    procAlive.get(w),
    faultCount < MAX_FAULTS,
    procAlive' = procAlive.set(w, false),
    wHeld' = wHeld.set(w, Set()),
    nodeSt' = nodeSt, nodeWorker' = nodeWorker, attempts' = attempts,
    life' = life, cpLive' = cpLive, commits' = commits,
    everComplete' = everComplete, inflight' = inflight,
  }

  // Heartbeat timeout: the host is declared lost. This is enabled whether or
  // not the process is really dead (false timeout).
  // spec: 07-julia-workers#HostSilent, 07-julia-workers#HostLost
  // spec: 07-julia-workers#WorkerDies
  action declareLost(w: str): bool = all {
    cpLive.get(w),
    faultCount < MAX_FAULTS,
    cpLive' = cpLive.set(w, false),
    life' = life.set(w, Stopped),
    nodeSt' = NODES.mapBy(n =>
      if (hit(w, n))
        (if (attempts.get(n) + 1 >= MAX_ATTEMPTS) Failed else Queued)
      else nodeSt.get(n)),
    attempts' = NODES.mapBy(n => if (hit(w, n)) attempts.get(n) + 1 else attempts.get(n)),
    nodeWorker' = NODES.mapBy(n => if (hit(w, n)) "" else nodeWorker.get(n)),
    commits' = commits, everComplete' = everComplete,
    procAlive' = procAlive, wHeld' = wHeld, inflight' = inflight,
  }

  action step = {
    nondet w = WORKERS.oneOf()
    nondet n = NODES.oneOf()
    any {
      takeBundle(w),
      workerFinishes(w, n),
      receive(w, n),
      commitBundle(w),
      procDies(w),
      declareLost(w),
    }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // BundleWithinLimit (spec 07).
  // spec: 07-julia-workers#BundleWithinLimit
  val bundleWithinLimit =
    WORKERS.forall(w => assignedTo(w).size() <= BUNDLE)

  // A completed node never leaves Complete, and is recorded once.
  val completeStaysComplete = everComplete.forall(n => nodeSt.get(n) == Complete)
  // spec: 07-julia-workers#BatchedLedgerWrite
  val committedOnce = NODES.forall(n => commits.get(n) <= 1)

  // A ticket is only held by a worker the control plane considers alive.
  val assignedToLive = NODES.forall(n =>
    if (nodeSt.get(n) == Assigned) cpLive.get(nodeWorker.get(n)) else true)

  val safety = and {
    bundleWithinLimit, completeStaysComplete, committedOnce, assignedToLive,
  }

  // No node is stuck waiting for a ledger commit that cannot happen.
  val noOrphanedReport = NODES.forall(n =>
    if (nodeSt.get(n) == Reported) cpLive.get(nodeWorker.get(n)) else true)

  // Progress witness: every node ends Complete or Failed. This is meant to be
  // violated; the violation is the example run that shows the protocol works.
  val notAllSettled = not(NODES.forall(n =>
    nodeSt.get(n) == Complete or nodeSt.get(n) == Failed))
}

module dispatch_mutant_no_reap {
  import bundled_dispatch(
    NODES = Set(0, 1, 2, 3, 4),
    WORKERS = Set("w1", "w2"),
    BUNDLE = 2,
    MAX_ATTEMPTS = 2,
    REAP_UNCOMMITTED = false,
    MAX_FAULTS = 2
  ).*
}

module dispatch {
  import bundled_dispatch(
    NODES = Set(0, 1, 2, 3, 4),
    WORKERS = Set("w1", "w2"),
    BUNDLE = 2,
    MAX_ATTEMPTS = 2,
    REAP_UNCOMMITTED = true,
    MAX_FAULTS = 2
  ).*
}
