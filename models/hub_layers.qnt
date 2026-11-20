// -*- mode: Quint -*-
//
// Shared layers ("hubs") of the plan, spec 02e (D-077).
//
// What is modelled: a plan in two kinds of node. Hubs are the nodes that the
// configuration release declares as shared by very many dependents (the USD
// swap curve, its fitted discount factors, its bumped curves), arranged in
// layers: a hub of a higher layer depends on hubs of a lower one. Positions
// are the dependents; each needs a set of hubs. Hosts compute hubs, keep the
// payloads they hold in a content-addressed cache, fetch a payload they lack
// at most once, and take bundles of positions only when they already hold every
// hub payload the bundle needs, all positions of a bundle needing the same hubs.
//
// What is not modelled: which nodes are declared hubs (planning, a
// configuration choice), the fan-in fallback, payload sizes, cache eviction,
// host loss and recomputation after a crash (bundled_dispatch.qnt and
// calc_graph.qnt cover those; a hub node is an ordinary node for them), the
// ledger. Cache eviction would allow a second fetch of a payload that was
// dropped: not modelled, so `payloadFetchedOncePerHost` states the property
// while the cache keeps what it holds.
//
// The instance `hubs` is the behaviour of spec 02e. Each `hubs_mutant_*`
// removes one control and is a negative control, NOT behaviour of the system:
// the gate requires each to violate the property that guards the control.

module hub_layers {
  const HUBS: Set[int]
  const HUB_DEPS: int -> Set[int]     // hubs a hub needs (all of a lower layer)
  const POSITIONS: Set[int]
  const NEEDS: int -> Set[int]        // hubs a position needs
  const HOSTS: Set[str]
  const BUNDLE: int                   // config.bundle_size
  const CHECK_LAYERS: bool            // a hub starts only after its prerequisites, on a host holding them
  const ONE_RUN: bool                 // a hub is computed once, not once per host
  const WARM_ONLY: bool               // positions go only to hosts holding their hubs
  const SAME_HUBS: bool               // a bundle holds positions that need the same hubs
  const CACHE_KEPT: bool              // a fetched payload stays on the host

  type HubSt = | HPending | HComputing | HComplete
  type PosSt = | PWaiting | PAssigned | PDone

  var hubSt: int -> HubSt
  var hubHost: int -> str             // host of the latest run, "" before
  var hubRuns: int -> int             // computations started
  var cache: str -> Set[int]          // hub payloads each host holds
  var fetchLog: List[(str, int)]      // every payload transfer to a host
  var posSt: int -> PosSt
  var posHost: int -> str

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------

  def completeHubs: Set[int] = HUBS.filter(h => hubSt.get(h) == HComplete)

  def assignedTo(w: str): Set[int] =
    POSITIONS.filter(p => posSt.get(p) == PAssigned and posHost.get(p) == w)

  // A payload is worth moving while something unfinished still needs it.
  def wanted(x: int): bool =
    or {
      POSITIONS.exists(p => posSt.get(p) != PDone and NEEDS.get(p).contains(x)),
      HUBS.exists(h => hubSt.get(h) != HComplete and HUB_DEPS.get(h).contains(x)),
    }

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  action init = all {
    hubSt' = HUBS.mapBy(h => HPending),
    hubHost' = HUBS.mapBy(h => ""),
    hubRuns' = HUBS.mapBy(h => 0),
    cache' = HOSTS.mapBy(w => Set()),
    fetchLog' = List(),
    posSt' = POSITIONS.mapBy(p => PWaiting),
    posHost' = POSITIONS.mapBy(p => ""),
  }

  // A host starts a hub. Layers are respected: every prerequisite hub is
  // complete and its payload is on this host. Without ONE_RUN a second host may
  // start a hub that is already computing, each host making its own.
  // spec: 02e-shared-layers#AssignOnWarmHost
  action computeHub(h: int, w: str): bool = all {
    or {
      hubSt.get(h) == HPending,
      and { not(ONE_RUN), hubSt.get(h) == HComputing },
    },
    or {
      not(CHECK_LAYERS),
      and { HUB_DEPS.get(h).subseteq(completeHubs), HUB_DEPS.get(h).subseteq(cache.get(w)) },
    },
    hubSt' = hubSt.set(h, HComputing),
    hubHost' = hubHost.set(h, w),
    hubRuns' = hubRuns.set(h, hubRuns.get(h) + 1),
    cache' = cache, fetchLog' = fetchLog, posSt' = posSt, posHost' = posHost,
  }

  // The hub is complete and its payload is on the host that computed it.
  // spec: 02e-shared-layers#HubCompleted
  action finishHub(h: int): bool = all {
    hubSt.get(h) == HComputing,
    hubSt' = hubSt.set(h, HComplete),
    cache' = cache.set(hubHost.get(h), cache.get(hubHost.get(h)).union(Set(h))),
    hubHost' = hubHost, hubRuns' = hubRuns, fetchLog' = fetchLog,
    posSt' = posSt, posHost' = posHost,
  }

  // A complete hub payload moves to a host that lacks it, once.
  // spec: 02e-shared-layers#PrefetchHubPayload
  action fetch(w: str, x: int): bool = all {
    hubSt.get(x) == HComplete,
    not(cache.get(w).contains(x)),
    wanted(x),
    cache' = cache.set(w, cache.get(w).union(Set(x))),
    fetchLog' = fetchLog.append((w, x)),
    hubSt' = hubSt, hubHost' = hubHost, hubRuns' = hubRuns,
    posSt' = posSt, posHost' = posHost,
  }

  // An idle host takes up to BUNDLE positions, lowest id first. Their hubs are
  // complete; unless WARM_ONLY is off, already on this host; and unless
  // SAME_HUBS is off, the same for every position of the bundle.
  // spec: 02e-shared-layers#AssignOnWarmHost
  action assignBundle(w: str): bool = {
    val ready = POSITIONS.filter(p =>
      and {
        posSt.get(p) == PWaiting,
        NEEDS.get(p).subseteq(completeHubs),
        or { not(WARM_ONLY), NEEDS.get(p).subseteq(cache.get(w)) },
      })
    val lead = ready.filter(p => ready.filter(q => q < p).size() == 0)
    val group = ready.filter(p =>
      or { not(SAME_HUBS), lead.exists(l => NEEDS.get(l) == NEEDS.get(p)) })
    val take = group.filter(p => group.filter(q => q < p).size() < BUNDLE)
    all {
      assignedTo(w).size() == 0,
      take.size() > 0,
      posSt' = POSITIONS.mapBy(p => if (take.contains(p)) PAssigned else posSt.get(p)),
      posHost' = POSITIONS.mapBy(p => if (take.contains(p)) w else posHost.get(p)),
      hubSt' = hubSt, hubHost' = hubHost, hubRuns' = hubRuns,
      cache' = cache, fetchLog' = fetchLog,
    }
  }

  // The host finishes a position. Without CACHE_KEPT the hub payloads are
  // dropped after use, so the next position fetches them again.
  action finishPosition(p: int): bool = all {
    posSt.get(p) == PAssigned,
    NEEDS.get(p).subseteq(cache.get(posHost.get(p))),
    posSt' = posSt.set(p, PDone),
    cache' = if (CACHE_KEPT) cache
             else cache.set(posHost.get(p), cache.get(posHost.get(p)).exclude(NEEDS.get(p))),
    hubSt' = hubSt, hubHost' = hubHost, hubRuns' = hubRuns,
    fetchLog' = fetchLog, posHost' = posHost,
  }

  action step = {
    nondet w = HOSTS.oneOf()
    nondet h = HUBS.oneOf()
    nondet p = POSITIONS.oneOf()
    nondet x = HUBS.oneOf()
    any {
      computeHub(h, w),
      finishHub(h),
      fetch(w, x),
      assignBundle(w),
      finishPosition(p),
    }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // A hub is computed once for the whole cluster, not once per host.
  // spec: 02e-shared-layers#OneComputationPerHub
  val oneComputationPerHub = HUBS.forall(h => hubRuns.get(h) <= 1)

  // A hub that has started had its prerequisites complete first (layer order).
  // spec: 02e-shared-layers#HubAfterPrerequisites
  val hubAfterPrerequisites = HUBS.forall(h =>
    or { hubSt.get(h) == HPending, HUB_DEPS.get(h).subseteq(completeHubs) })

  // A payload goes to a host at most once.
  // spec: 02e-shared-layers#PayloadFetchedOncePerHost
  val payloadFetchedOncePerHost =
    fetchLog.indices().forall(i =>
      fetchLog.indices().forall(j => or { i == j, fetchLog[i] != fetchLog[j] }))

  // A position runs only on a host that already holds every hub it needs.
  // spec: 02e-shared-layers#DependentsRunOnWarmHosts
  val dependentsRunOnWarmHosts = POSITIONS.forall(p =>
    or {
      posSt.get(p) != PAssigned,
      NEEDS.get(p).subseteq(cache.get(posHost.get(p))),
    })

  // The positions of a bundle need the same hubs.
  // spec: 02e-shared-layers#BundleSharesHubs
  val bundleSharesHubs = HOSTS.forall(w =>
    assignedTo(w).map(p => NEEDS.get(p)).size() <= 1)

  val bundleWithinLimit = HOSTS.forall(w => assignedTo(w).size() <= BUNDLE)

  // A started position has all its hubs complete; a cache holds only complete hubs.
  val positionAfterHubs = POSITIONS.forall(p =>
    or { posSt.get(p) == PWaiting, NEEDS.get(p).subseteq(completeHubs) })
  val cacheHoldsCompleteHubs = HOSTS.forall(w => cache.get(w).subseteq(completeHubs))

  val safety = and {
    oneComputationPerHub, hubAfterPrerequisites, payloadFetchedOncePerHost,
    dependentsRunOnWarmHosts, bundleSharesHubs, bundleWithinLimit,
    positionAfterHubs, cacheHoldsCompleteHubs,
  }

  // Progress witness: every position ends done. Meant to be violated; the
  // violation is the example run that shows the protocol works.
  val notAllDone = not(POSITIONS.forall(p => posSt.get(p) == PDone))
}

// Two currency families: hubs 0 and 1 are fitted curves (layer 0), 2 and 3 their
// bumped sets (layer 1). Positions 0-2 use the first family, 3-4 the second,
// 5 both.
module hubs {
  import hub_layers(
    HUBS = Set(0, 1, 2, 3),
    HUB_DEPS = Map(0 -> Set(), 1 -> Set(), 2 -> Set(0), 3 -> Set(1)),
    POSITIONS = Set(0, 1, 2, 3, 4, 5),
    NEEDS = Map(
      0 -> Set(0, 2), 1 -> Set(0, 2), 2 -> Set(0, 2),
      3 -> Set(1, 3), 4 -> Set(1, 3), 5 -> Set(0, 1, 2, 3)
    ),
    HOSTS = Set("w1", "w2"),
    BUNDLE = 2,
    CHECK_LAYERS = true,
    ONE_RUN = true,
    WARM_ONLY = true,
    SAME_HUBS = true,
    CACHE_KEPT = true
  ).*
}

module hubs_mutant_no_layers {
  import hub_layers(
    HUBS = Set(0, 1, 2, 3),
    HUB_DEPS = Map(0 -> Set(), 1 -> Set(), 2 -> Set(0), 3 -> Set(1)),
    POSITIONS = Set(0, 1, 2, 3, 4, 5),
    NEEDS = Map(
      0 -> Set(0, 2), 1 -> Set(0, 2), 2 -> Set(0, 2),
      3 -> Set(1, 3), 4 -> Set(1, 3), 5 -> Set(0, 1, 2, 3)
    ),
    HOSTS = Set("w1", "w2"),
    BUNDLE = 2,
    CHECK_LAYERS = false,
    ONE_RUN = true,
    WARM_ONLY = true,
    SAME_HUBS = true,
    CACHE_KEPT = true
  ).*
}

module hubs_mutant_every_host_computes {
  import hub_layers(
    HUBS = Set(0, 1, 2, 3),
    HUB_DEPS = Map(0 -> Set(), 1 -> Set(), 2 -> Set(0), 3 -> Set(1)),
    POSITIONS = Set(0, 1, 2, 3, 4, 5),
    NEEDS = Map(
      0 -> Set(0, 2), 1 -> Set(0, 2), 2 -> Set(0, 2),
      3 -> Set(1, 3), 4 -> Set(1, 3), 5 -> Set(0, 1, 2, 3)
    ),
    HOSTS = Set("w1", "w2"),
    BUNDLE = 2,
    CHECK_LAYERS = true,
    ONE_RUN = false,
    WARM_ONLY = true,
    SAME_HUBS = true,
    CACHE_KEPT = true
  ).*
}

module hubs_mutant_cold_hosts {
  import hub_layers(
    HUBS = Set(0, 1, 2, 3),
    HUB_DEPS = Map(0 -> Set(), 1 -> Set(), 2 -> Set(0), 3 -> Set(1)),
    POSITIONS = Set(0, 1, 2, 3, 4, 5),
    NEEDS = Map(
      0 -> Set(0, 2), 1 -> Set(0, 2), 2 -> Set(0, 2),
      3 -> Set(1, 3), 4 -> Set(1, 3), 5 -> Set(0, 1, 2, 3)
    ),
    HOSTS = Set("w1", "w2"),
    BUNDLE = 2,
    CHECK_LAYERS = true,
    ONE_RUN = true,
    WARM_ONLY = false,
    SAME_HUBS = true,
    CACHE_KEPT = true
  ).*
}

module hubs_mutant_mixed_bundles {
  import hub_layers(
    HUBS = Set(0, 1, 2, 3),
    HUB_DEPS = Map(0 -> Set(), 1 -> Set(), 2 -> Set(0), 3 -> Set(1)),
    POSITIONS = Set(0, 1, 2, 3, 4, 5),
    NEEDS = Map(
      0 -> Set(0, 2), 1 -> Set(0, 2), 2 -> Set(0, 2),
      3 -> Set(1, 3), 4 -> Set(1, 3), 5 -> Set(0, 1, 2, 3)
    ),
    HOSTS = Set("w1", "w2"),
    BUNDLE = 2,
    CHECK_LAYERS = true,
    ONE_RUN = true,
    WARM_ONLY = true,
    SAME_HUBS = false,
    CACHE_KEPT = true
  ).*
}

module hubs_mutant_no_cache {
  import hub_layers(
    HUBS = Set(0, 1, 2, 3),
    HUB_DEPS = Map(0 -> Set(), 1 -> Set(), 2 -> Set(0), 3 -> Set(1)),
    POSITIONS = Set(0, 1, 2, 3, 4, 5),
    NEEDS = Map(
      0 -> Set(0, 2), 1 -> Set(0, 2), 2 -> Set(0, 2),
      3 -> Set(1, 3), 4 -> Set(1, 3), 5 -> Set(0, 1, 2, 3)
    ),
    HOSTS = Set("w1", "w2"),
    BUNDLE = 2,
    CHECK_LAYERS = true,
    ONE_RUN = true,
    WARM_ONLY = true,
    SAME_HUBS = true,
    CACHE_KEPT = false
  ).*
}
