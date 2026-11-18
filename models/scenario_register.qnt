// -*- mode: Quint -*-
//
// The scenario register (spec 25, D-068): versions of a scenario set are drafted,
// submitted, approved by someone other than their author, run, and retired.
//
// What is modelled: one set with versions 1..N; per version a status, an
// author, an approver, a content value and the content recorded at approval, a
// scheduled flag; runs (scheduled by the batch, or ad hoc) started on a version;
// retirement; the replacement of an older scheduled version when a newer one
// is approved scheduled. Content may be edited only in draft.
//
// What is not modelled: the content itself, perimeters, results, calc_ids,
// closing a set, the historical knowledge time.
//
// Authority (D-055): authoritative for the behaviour it covers. `register` is
// the behaviour; each `register_mutant_*` removes one control and the gate
// requires the matching property to fail:
// `no_signer_check` (author may approve; approverIndependent),
// `edit_after_submit` (content changes past draft; contentFrozen),
// `run_any_status` (a run on an unapproved version; runsOnlyApproved),
// `no_retire_clear` (a retired version stays scheduled; scheduledApproved),
// `no_replace` (two scheduled versions at once; oneScheduled).

module scenario_register {
  const VERSIONS: Set[int]
  const USERS: Set[str]
  const MUTANT: str

  type St = | NoVer | Draft | Submitted | Approved | Rejected | Retired

  var st: int -> St
  var author: int -> str
  var approver: int -> str
  var content: int -> int
  var approvedContent: int -> int     // ghost: content when approved (-1: not yet)
  var sched: int -> bool
  var badRun: bool                    // ghost: a run started on a version not approved

  action init = all {
    st' = VERSIONS.mapBy(v => NoVer),
    author' = VERSIONS.mapBy(v => ""),
    approver' = VERSIONS.mapBy(v => ""),
    content' = VERSIONS.mapBy(v => 0),
    approvedContent' = VERSIONS.mapBy(v => -1),
    sched' = VERSIONS.mapBy(v => false),
    badRun' = false,
  }

  // spec: 25-governed-scenarios#DraftVersion
  action draft(v: int, a: str, c: int): bool = all {
    st.get(v) == NoVer,
    st' = st.set(v, Draft),
    author' = author.set(v, a),
    content' = content.set(v, c),
    approver' = approver, approvedContent' = approvedContent,
    sched' = sched, badRun' = badRun,
  }

  // Editing a draft; the mutant also lets a submitted or approved one change.
  action edit(v: int, c: int): bool = all {
    st.get(v) == Draft
      or (MUTANT == "edit_after_submit" and (st.get(v) == Submitted or st.get(v) == Approved)),
    content' = content.set(v, c),
    st' = st, author' = author, approver' = approver,
    approvedContent' = approvedContent, sched' = sched, badRun' = badRun,
  }

  // spec: 25-governed-scenarios#SubmitVersion
  action submit(v: int, a: str): bool = all {
    st.get(v) == Draft,
    author.get(v) == a,
    st' = st.set(v, Submitted),
    author' = author, approver' = approver, content' = content,
    approvedContent' = approvedContent, sched' = sched, badRun' = badRun,
  }

  // Approval; a version approved as scheduled retires any other scheduled one.
  // spec: 25-governed-scenarios#ApproveVersion, 25-governed-scenarios#ReplaceScheduledVersion
  action approve(v: int, p: str, s: bool): bool = all {
    st.get(v) == Submitted,
    MUTANT == "no_signer_check" or p != author.get(v),
    st' = VERSIONS.mapBy(w =>
      if (w == v) Approved
      else if (s and MUTANT != "no_replace" and st.get(w) == Approved and sched.get(w)) Retired
      else st.get(w)),
    sched' = VERSIONS.mapBy(w =>
      if (w == v) s
      else if (s and MUTANT != "no_replace") false
      else sched.get(w)),
    approver' = approver.set(v, p),
    approvedContent' = approvedContent.set(v, content.get(v)),
    author' = author, content' = content, badRun' = badRun,
  }

  // spec: 25-governed-scenarios#RejectVersion
  action reject(v: int, p: str): bool = all {
    st.get(v) == Submitted,
    p != author.get(v),
    st' = st.set(v, Rejected),
    author' = author, approver' = approver, content' = content,
    approvedContent' = approvedContent, sched' = sched, badRun' = badRun,
  }

  // spec: 25-governed-scenarios#RetireVersion
  action retire(v: int): bool = all {
    st.get(v) == Approved,
    st' = st.set(v, Retired),
    sched' = if (MUTANT == "no_retire_clear") sched else sched.set(v, false),
    author' = author, approver' = approver, content' = content,
    approvedContent' = approvedContent, badRun' = badRun,
  }

  // A run starts on a version: scheduled (flag set) or ad hoc.
  // spec: 25b-stress-runs#StartScheduledStress, 25b-stress-runs#RequestAdhocStress
  // spec: 25b-stress-runs#StressCompletes
  action startRun(v: int): bool = all {
    st.get(v) != NoVer,
    MUTANT == "run_any_status" or st.get(v) == Approved,
    badRun' = (badRun or st.get(v) != Approved),
    st' = st, author' = author, approver' = approver, content' = content,
    approvedContent' = approvedContent, sched' = sched,
  }

  action step = {
    nondet v = VERSIONS.oneOf()
    nondet u = USERS.oneOf()
    nondet c = Set(1, 2).oneOf()
    nondet s = Set(true, false).oneOf()
    any {
      draft(v, u, c), edit(v, c), submit(v, u), approve(v, u, s),
      reject(v, u), retire(v), startRun(v),
    }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // spec: 25-governed-scenarios#ApproverIsNotAuthor
  val approverIndependent = VERSIONS.forall(v =>
    (st.get(v) != Approved and st.get(v) != Retired) or approver.get(v) != author.get(v))

  // The content never changes once approved (register has no edit past draft).
  val contentFrozen = VERSIONS.forall(v =>
    approvedContent.get(v) == -1 or content.get(v) == approvedContent.get(v))

  // spec: 25b-stress-runs#RunsUseApprovedVersions
  val runsOnlyApproved = not(badRun)

  // spec: 25-governed-scenarios#ScheduledMeansApproved
  val scheduledApproved = VERSIONS.forall(v => not(sched.get(v)) or st.get(v) == Approved)

  // A set is stressed once a day: at most one scheduled version.
  val oneScheduled = VERSIONS.filter(v => sched.get(v)).size() <= 1

  val safety = and {
    approverIndependent, contentFrozen, runsOnlyApproved, scheduledApproved, oneScheduled,
  }

  // Witness, meant to be violated: a version is approved and scheduled.
  val notScheduled = not(VERSIONS.exists(v => sched.get(v)))
}

module register {
  import scenario_register(VERSIONS = Set(1, 2, 3), USERS = Set("ann", "bo"), MUTANT = "").*
}

module register_mutant_no_signer_check {
  import scenario_register(VERSIONS = Set(1, 2, 3), USERS = Set("ann", "bo"), MUTANT = "no_signer_check").*
}

module register_mutant_edit_after_submit {
  import scenario_register(VERSIONS = Set(1, 2, 3), USERS = Set("ann", "bo"), MUTANT = "edit_after_submit").*
}

module register_mutant_run_any_status {
  import scenario_register(VERSIONS = Set(1, 2, 3), USERS = Set("ann", "bo"), MUTANT = "run_any_status").*
}

module register_mutant_no_retire_clear {
  import scenario_register(VERSIONS = Set(1, 2, 3), USERS = Set("ann", "bo"), MUTANT = "no_retire_clear").*
}

module register_mutant_no_replace {
  import scenario_register(VERSIONS = Set(1, 2, 3), USERS = Set("ann", "bo"), MUTANT = "no_replace").*
}
