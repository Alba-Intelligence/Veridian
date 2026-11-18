// -*- mode: Quint -*-
//
// The ephemeral tier of calculation nodes (spec 23, D-066): nodes made for
// interactive work may expire or be evicted; a durable request adopts an
// ephemeral node it needs (promotion) together with the prerequisites the node
// records.
//
// What is modelled: a few nodes with recorded prerequisites (PRE, chains of at
// most three), each Absent, Ephemeral or Durable; steps bound to nodes by a
// durable or an interactive request; expiry (time is nondeterministic); the
// size cap with eviction of an evictable node. A node is evictable when it is
// ephemeral, has no running step and is no present node's prerequisite.
// Creation or reuse binds one step; ending a step unpins the node.
//
// What is not modelled: calc_ids and results (a node is its identity),
// last-use ordering (the victim is any evictable node), sizes (every node
// counts one), recomputation after expiry, data classes, the impact class (24).
//
// Authority (D-055): authoritative for the behaviour it covers. Instances at
// the bottom: `tier` is the behaviour; `tier_mutant_*` each remove one control
// and the gate requires the matching property to fail:
// `no_cascade` (promotion stops at the node, durablePrereqsDurable),
// `no_promote` (a durable step on an ephemeral node, durableUsesDurable),
// `no_running_guard` (expiry under a running step, runningNodePresent),
// `no_dep_guard` (expiry under a dependent, noDangling) and
// `no_evict` (no eviction at the cap, capHolds).

module ephemeral_tier {
  const NODES: Set[int]
  const PRE: int -> Set[int]       // prerequisite nodes recorded on each node
  const CAP: int                   // most ephemeral nodes
  const MUTANT: str                // "" in the system; names one removed control

  type St = | Absent | Eph | Dur

  var st: int -> St
  var running: int -> int          // steps running on the node, of any request
  var durRunning: int -> int       // of which from durable requests
  var wasDurable: int -> bool      // ghost: the node was promoted or made durable

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------

  def present(s: int -> St, n: int): bool = s.get(n) != Absent

  def hasDependent(s: int -> St, n: int): bool =
    NODES.exists(m => present(s, m) and PRE.get(m).contains(n))

  def evictable(s: int -> St, rn: int -> int, n: int): bool =
    s.get(n) == Eph and rn.get(n) == 0 and not(hasDependent(s, n))

  def ephCount(s: int -> St): int = NODES.filter(n => s.get(n) == Eph).size()

  // The node and the prerequisites it records, and theirs (chains of at most
  // three nodes).
  def closure(n: int): Set[int] =
    Set(n).union(PRE.get(n)).union(
      PRE.get(n).fold(Set(), (a, p) => a.union(PRE.get(p))))

  // Over the cap, one evictable node goes (the lowest id stands for the least
  // recently used).
  def settleOnce(s: int -> St, rn: int -> int): int -> St = {
    val victims = NODES.filter(n => evictable(s, rn, n))
    if (MUTANT != "no_evict" and ephCount(s) > CAP and victims.size() > 0)
      s.set(victims.fold(100, (a, n) => if (n < a) n else a), Absent)
    else s
  }

  // The spec repeats the eviction while the tier is over the cap and a node
  // may go (the event that triggers it is raised again after each eviction);
  // one pass per node is enough.
  // spec: 23-ephemeral-tier#EvictWhenOverCap
  def settle(s: int -> St, rn: int -> int): int -> St =
    NODES.fold(s, (acc, n) => settleOnce(acc, rn))

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  action init = all {
    st' = NODES.mapBy(n => Absent),
    running' = NODES.mapBy(n => 0),
    durRunning' = NODES.mapBy(n => 0),
    wasDurable' = NODES.mapBy(n => false),
  }

  // A step binds to no node and creates one: ephemeral when the request is
  // interactive, durable when it is not (its prerequisites are its own bound
  // steps, so durable already).
  // spec: 23-ephemeral-tier#ClassifyNewNode
  action create(n: int, d: bool): bool = {
    val ns = st.set(n, if (d) Dur else Eph)
    all {
      st.get(n) == Absent,
      PRE.get(n).forall(p => present(st, p)),
      d implies PRE.get(n).forall(p => st.get(p) == Dur),
      st' = settle(ns, running.set(n, running.get(n) + 1)),
      running' = running.set(n, running.get(n) + 1),
      durRunning' = if (d) durRunning.set(n, durRunning.get(n) + 1) else durRunning,
      wasDurable' = if (d) wasDurable.set(n, true) else wasDurable,
    }
  }

  // A step finds an existing node: an interactive step only keeps it alive; a
  // durable step adopts it, promoting it with its recorded prerequisites.
  // spec: 23-ephemeral-tier#TouchOnInteractiveReuse, 23-ephemeral-tier#PromoteOnOfficialReuse
  // spec: 23-ephemeral-tier#PromoteNode
  action reuse(n: int, d: bool): bool = {
    val promoted = if (MUTANT == "no_cascade") Set(n) else closure(n)
    val ns =
      if (d and MUTANT != "no_promote")
        NODES.mapBy(m => if (promoted.contains(m) and st.get(m) == Eph) Dur else st.get(m))
      else st
    all {
      present(st, n),
      st' = ns,
      running' = running.set(n, running.get(n) + 1),
      durRunning' = if (d) durRunning.set(n, durRunning.get(n) + 1) else durRunning,
      wasDurable' =
        if (d and MUTANT != "no_promote")
          NODES.mapBy(m => wasDurable.get(m) or (promoted.contains(m) and st.get(m) != Absent))
        else wasDurable,
    }
  }

  // The step ends; an unpinned node may now be evicted if the tier is over.
  // spec: 23-ephemeral-tier#RecheckTierWhenStepEnds, 23-ephemeral-tier#RecheckTierWhenStepAbandoned
  action endStep(n: int, d: bool): bool = all {
    running.get(n) > 0,
    d implies durRunning.get(n) > 0,
    running' = running.set(n, running.get(n) - 1),
    durRunning' = if (d) durRunning.set(n, durRunning.get(n) - 1) else durRunning,
    st' = settle(st, running.set(n, running.get(n) - 1)),
    wasDurable' = wasDurable,
  }

  // Time: an unused ephemeral node goes, under the guards of the spec.
  // spec: 23-ephemeral-tier#ExpireEphemeralNode
  action expire(n: int): bool = all {
    st.get(n) == Eph,
    MUTANT == "no_running_guard" or running.get(n) == 0,
    MUTANT == "no_dep_guard" or not(hasDependent(st, n)),
    st' = st.set(n, Absent),
    running' = running, durRunning' = durRunning, wasDurable' = wasDurable,
  }

  action step = {
    nondet n = NODES.oneOf()
    nondet d = Set(true, false).oneOf()
    any { create(n, d), reuse(n, d), endStep(n, d), expire(n) }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // A durable node never points at an ephemeral one.
  // spec: 23-ephemeral-tier#DurableNodesHaveDurablePrerequisites
  val durablePrereqsDurable = NODES.forall(n =>
    st.get(n) != Dur or PRE.get(n).forall(p => st.get(p) == Dur))

  // A durable request's running step is on a durable node.
  // spec: 23-ephemeral-tier#DurableRequestsUseDurableNodes
  val durableUsesDurable = NODES.forall(n =>
    durRunning.get(n) == 0 or st.get(n) == Dur)

  // No present node points at a missing prerequisite.
  // spec: 23-ephemeral-tier#NothingDangles
  val noDangling = NODES.forall(n =>
    not(present(st, n)) or PRE.get(n).forall(p => present(st, p)))

  // A running step never loses its node.
  val runningNodePresent = NODES.forall(n => running.get(n) == 0 or present(st, n))

  // A node that was durable stays durable.
  val durableStays = NODES.forall(n => not(wasDurable.get(n)) or st.get(n) == Dur)

  // The tier is within the cap unless every ephemeral node is pinned.
  val capHolds = ephCount(st) <= CAP or not(NODES.exists(n => evictable(st, running, n)))

  val safety = and {
    durablePrereqsDurable, durableUsesDurable, noDangling,
    runningNodePresent, durableStays, capHolds,
  }

  // Witness, meant to be violated: a node is promoted together with a
  // prerequisite.
  val notPromoted = not(NODES.exists(n => wasDurable.get(n) and PRE.get(n).size() > 0))
}

// Nodes 1 and 3 have no prerequisite; 2 records 1, 4 records 2 and 3. The cap
// of two makes eviction reachable.
module tier {
  import ephemeral_tier(
    NODES = Set(1, 2, 3, 4),
    PRE = Map(1 -> Set(), 2 -> Set(1), 3 -> Set(), 4 -> Set(2, 3)),
    CAP = 2,
    MUTANT = ""
  ).*
}

module tier_mutant_no_cascade {
  import ephemeral_tier(
    NODES = Set(1, 2, 3, 4),
    PRE = Map(1 -> Set(), 2 -> Set(1), 3 -> Set(), 4 -> Set(2, 3)),
    CAP = 2,
    MUTANT = "no_cascade"
  ).*
}

module tier_mutant_no_promote {
  import ephemeral_tier(
    NODES = Set(1, 2, 3, 4),
    PRE = Map(1 -> Set(), 2 -> Set(1), 3 -> Set(), 4 -> Set(2, 3)),
    CAP = 2,
    MUTANT = "no_promote"
  ).*
}

module tier_mutant_no_running_guard {
  import ephemeral_tier(
    NODES = Set(1, 2, 3, 4),
    PRE = Map(1 -> Set(), 2 -> Set(1), 3 -> Set(), 4 -> Set(2, 3)),
    CAP = 2,
    MUTANT = "no_running_guard"
  ).*
}

module tier_mutant_no_dep_guard {
  import ephemeral_tier(
    NODES = Set(1, 2, 3, 4),
    PRE = Map(1 -> Set(), 2 -> Set(1), 3 -> Set(), 4 -> Set(2, 3)),
    CAP = 2,
    MUTANT = "no_dep_guard"
  ).*
}

module tier_mutant_no_evict {
  import ephemeral_tier(
    NODES = Set(1, 2, 3, 4),
    PRE = Map(1 -> Set(), 2 -> Set(1), 3 -> Set(), 4 -> Set(2, 3)),
    CAP = 2,
    MUTANT = "no_evict"
  ).*
}
