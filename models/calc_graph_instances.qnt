// -*- mode: Quint -*-
//
// Instances of the calculation-graph model (calc_graph.qnt, spec 02) for the
// simulation checks: `calc_graph_fixed` is the behaviour (D-062: one
// recomputation per purged payload; abandon at binding; D-063: a lost
// recomputation is retried, then ends its waiting steps). The `mutant_*`
// instances are negative controls, not behaviour: each removes one control and
// the gate requires it to violate the matching property or scenario
// (calc_graph_scenarios.qnt, same names), so the properties are known to have
// teeth: `no_stampede` (oneInFlight), `dup_remat` (before D-062:
// oneRematInFlight), `remat_broken` (before D-062: noRematOnBroken) and
// `remat_lost` (before D-063: purgedWaiterHasRemat).
//
// Three requests: 1 and 3 share an input (memo, stampede); 1 and 2 differ in
// input but their A results are equal (early cutoff, one shared B node).

module calc_graph_fixed {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "fixed"
  ).* from "./calc_graph"
}

module calc_graph_mutant_no_stampede {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "mutant_no_stampede"
  ).* from "./calc_graph"
}

module calc_graph_mutant_dup_remat {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "mutant_dup_remat"
  ).* from "./calc_graph"
}

module calc_graph_mutant_remat_broken {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "mutant_remat_broken"
  ).* from "./calc_graph"
}

module calc_graph_mutant_remat_lost {
  import calc_graph(
    REQS = Set(1, 2, 3),
    INPUT = Map(1 -> 1, 2 -> 2, 3 -> 1),
    RESULT = Map(1 -> 7, 2 -> 7),
    MAX_ATTEMPTS = 2,
    VARIANT = "mutant_remat_lost"
  ).* from "./calc_graph"
}
