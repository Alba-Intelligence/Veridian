// -*- mode: Quint -*-
//
// The production release gate: configuration releases (spec 05) against model
// validations and benchmark breaches (spec 21), D-050 and D-051.
//
// What is modelled: releases that are submitted, then evaluated (activated or
// refused) at a separate step, so a validation can expire or be withdrawn, or a
// breach can open, between the two; one active release at a time, replaced
// atomically; reviewer independence of releases; validator and breach-reviewer
// independence of models; each release names the model versions it adds or
// changes, and the gate applies to those only (D-058): a release that changes
// no model passes whatever the state of the validations.
//
// What is not modelled: scheduled activation and expiry of received releases,
// the verification of signatures and golden tests, validation outcomes other
// than approved, scope, tiers and intervals, conditions, alerts, development
// releases, several kinds of release.
//
// Authority (D-055): this model is authoritative for the behaviour it covers.
//
// Instances at the bottom: `gate` is the behaviour. The `gate_mutant_*`
// instances each remove one control (the gate, the atomic supersession, the
// reviewer rule) or revert one decision (`all_models`: the gate on every model,
// as before D-058). They are not behaviour: they are negative controls that the
// gate script requires to violate the matching property, so the properties are
// known to have teeth.

module release_gate {
  const RELEASES: Set[int]
  const MODELS: Set[str]
  const USERS: Set[str]
  const VALIDATORS: Set[str]        // users permitted "model.validate"
  const OWNER: str -> str           // owner of each model's inventory entry
  const FIRST_AUTHOR: str -> str    // author of the release that first carried the version
  const MUTANT: str                 // "" in the system; names one removed control otherwise

  type RelSt = | NoRel | Received | Active | Superseded | Refused
  type ValSt = | NoVal | Current | Expired | Withdrawn
  type BrSt = | NoBreach | Open | Reviewed
  type Cause = | NoCause | ReviewCause | GateCause | BothCause

  var relSt: int -> RelSt
  var author: int -> str
  var reviewers: int -> Set[str]
  // Graph model versions (D-060) that differ from the active release's; an
  // abstract set here, a model is its graph model version.
  var changes: int -> Set[str]
  var refusal: int -> Cause                 // why a release was refused
  var clearedAtActivation: int -> bool      // ghost: the gate held when it activated
  var valSt: str -> ValSt
  var validator: str -> str
  var breach: str -> BrSt
  var breachReviewer: str -> str

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------

  // At least one reviewer, none of them the author (ProductionReleasesAreReviewed).
  def reviewedOk(r: int): bool =
    reviewers.get(r).size() >= 1 and not(reviewers.get(r).contains(author.get(r)))

  // A model is fit for release: a current validation and no open breach.
  def modelFit(m: str): bool = valSt.get(m) == Current and breach.get(m) != Open

  // models_cleared (D-058): the model versions the release adds or changes are
  // fit. Versions carried forward unchanged are not looked at.
  def gateOk(r: int): bool =
    if (MUTANT == "all_models") MODELS.forall(m => modelFit(m))
    else changes.get(r).forall(m => modelFit(m))

  // ------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------

  action init = all {
    relSt' = RELEASES.mapBy(r => NoRel),
    author' = RELEASES.mapBy(r => ""),
    reviewers' = RELEASES.mapBy(r => Set()),
    changes' = RELEASES.mapBy(r => Set()),
    refusal' = RELEASES.mapBy(r => NoCause),
    clearedAtActivation' = RELEASES.mapBy(r => false),
    valSt' = MODELS.mapBy(m => NoVal),
    validator' = MODELS.mapBy(m => ""),
    breach' = MODELS.mapBy(m => NoBreach),
    breachReviewer' = MODELS.mapBy(m => ""),
  }

  // The loader hands over a production release with its review evidence.
  // spec: 05-configuration-release#ReceiveRelease
  action submit(r: int, a: str, revs: Set[str], chg: Set[str]): bool = all {
    relSt.get(r) == NoRel,
    relSt' = relSt.set(r, Received),
    changes' = changes.set(r, chg),
    author' = author.set(r, a),
    reviewers' = reviewers.set(r, revs),
    refusal' = refusal, clearedAtActivation' = clearedAtActivation,
    valSt' = valSt, validator' = validator, breach' = breach,
    breachReviewer' = breachReviewer,
  }

  // Activation and supersession of the previous active release are one step.
  // spec: 05-configuration-release#ActivateRelease
  // spec: 05-configuration-release#SupersedePreviousRelease
  action activate(r: int): bool = all {
    relSt.get(r) == Received,
    MUTANT == "no_review" or reviewedOk(r),
    MUTANT == "no_gate" or gateOk(r),
    changes' = changes,
    relSt' = RELEASES.mapBy(x =>
      if (x == r) Active
      else if (MUTANT != "no_supersede" and relSt.get(x) == Active) Superseded
      else relSt.get(x)),
    // Ghost: the state of the gate at the instant of activation.
    clearedAtActivation' = clearedAtActivation.set(r, gateOk(r)),
    author' = author, reviewers' = reviewers, refusal' = refusal,
    valSt' = valSt, validator' = validator, breach' = breach,
    breachReviewer' = breachReviewer,
  }

  // spec: 05-configuration-release#RefuseRelease
  action refuse(r: int): bool = all {
    relSt.get(r) == Received,
    not(reviewedOk(r)) or not(gateOk(r)),
    changes' = changes,
    relSt' = relSt.set(r, Refused),
    refusal' = refusal.set(r,
      if (not(reviewedOk(r)) and not(gateOk(r))) BothCause
      else if (not(reviewedOk(r))) ReviewCause
      else GateCause),
    author' = author, reviewers' = reviewers,
    clearedAtActivation' = clearedAtActivation,
    valSt' = valSt, validator' = validator, breach' = breach,
    breachReviewer' = breachReviewer,
  }

  // A validator who is neither the owner nor the author of the release that
  // carried the version; a new validation replaces the previous one.
  // spec: 21b-model-validation#RecordValidation
  action recordValidation(m: str, v: str): bool = all {
    VALIDATORS.contains(v),
    v != OWNER.get(m),
    v != FIRST_AUTHOR.get(m),
    changes' = changes,
    valSt' = valSt.set(m, Current),
    validator' = validator.set(m, v),
    relSt' = relSt, author' = author, reviewers' = reviewers, refusal' = refusal,
    clearedAtActivation' = clearedAtActivation, breach' = breach,
    breachReviewer' = breachReviewer,
  }

  // spec: 21b-model-validation#ValidationExpires
  action expire(m: str): bool = all {
    valSt.get(m) == Current,
    changes' = changes,
    valSt' = valSt.set(m, Expired),
    validator' = validator, relSt' = relSt, author' = author,
    reviewers' = reviewers, refusal' = refusal,
    clearedAtActivation' = clearedAtActivation, breach' = breach,
    breachReviewer' = breachReviewer,
  }

  // spec: 21b-model-validation#WithdrawValidation
  action withdraw(m: str, v: str): bool = all {
    valSt.get(m) == Current,
    VALIDATORS.contains(v),
    changes' = changes,
    valSt' = valSt.set(m, Withdrawn),
    validator' = validator, relSt' = relSt, author' = author,
    reviewers' = reviewers, refusal' = refusal,
    clearedAtActivation' = clearedAtActivation, breach' = breach,
    breachReviewer' = breachReviewer,
  }

  // A benchmark outside tolerance opens a breach (it needs a current validation).
  // spec: 21c-benchmarks-and-breaches#RaiseBreach
  action benchmarkOutside(m: str): bool = all {
    valSt.get(m) == Current,
    changes' = changes,
    breach' = breach.set(m, Open),
    valSt' = valSt, validator' = validator, relSt' = relSt, author' = author,
    reviewers' = reviewers, refusal' = refusal,
    clearedAtActivation' = clearedAtActivation, breachReviewer' = breachReviewer,
  }

  // spec: 21c-benchmarks-and-breaches#ReviewBreach
  action reviewBreach(m: str, v: str): bool = all {
    breach.get(m) == Open,
    VALIDATORS.contains(v),
    v != OWNER.get(m),
    changes' = changes,
    breach' = breach.set(m, Reviewed),
    breachReviewer' = breachReviewer.set(m, v),
    valSt' = valSt, validator' = validator, relSt' = relSt, author' = author,
    reviewers' = reviewers, refusal' = refusal,
    clearedAtActivation' = clearedAtActivation,
  }

  action step = {
    nondet r = RELEASES.oneOf()
    nondet a = USERS.oneOf()
    nondet revs = USERS.powerset().oneOf()
    nondet chg = MODELS.powerset().oneOf()
    nondet m = MODELS.oneOf()
    nondet v = USERS.oneOf()
    any {
      submit(r, a, revs, chg),
      activate(r),
      refuse(r),
      recordValidation(m, v),
      expire(m),
      withdraw(m, v),
      benchmarkOutside(m),
      reviewBreach(m, v),
    }
  }

  // ------------------------------------------------------------
  // Properties
  // ------------------------------------------------------------

  // spec: 05-configuration-release#OneActiveReleasePerKind
  val oneActive =
    RELEASES.filter(r => relSt.get(r) == Active).size() <= 1

  // spec: 05-configuration-release#ProductionReleasesAreReviewed
  val reviewedProduction = RELEASES.forall(r =>
    if (relSt.get(r) == Active or relSt.get(r) == Superseded) reviewedOk(r) else true)

  // The gate held at the instant of activation, whatever happened since.
  val gateHeldAtActivation = RELEASES.forall(r =>
    if (relSt.get(r) == Active or relSt.get(r) == Superseded) clearedAtActivation.get(r)
    else true)

  // spec: 21b-model-validation#ValidatorIsIndependent
  val validatorIndependent = MODELS.forall(m =>
    if (valSt.get(m) != NoVal)
      validator.get(m) != OWNER.get(m) and validator.get(m) != FIRST_AUTHOR.get(m)
    else true)

  // spec: 21c-benchmarks-and-breaches#ReviewerIsIndependent
  val reviewerIndependent = MODELS.forall(m =>
    if (breach.get(m) == Reviewed) breachReviewer.get(m) != OWNER.get(m) else true)

  // D-058: a release that adds or changes no model is never refused by the
  // model gate, whatever the state of any validation.
  // spec: 05-configuration-release#RefuseRelease
  val noGateRefusalWithoutChange = RELEASES.forall(r =>
    if (refusal.get(r) == GateCause or refusal.get(r) == BothCause)
      changes.get(r).size() > 0
    else true)

  val safety = and {
    oneActive, reviewedProduction, gateHeldAtActivation,
    validatorIndependent, reviewerIndependent, noGateRefusalWithoutChange,
  }

  // Witnesses, meant to be violated (the violation is the example run).
  // A release can be activated.
  val notActivated = not(RELEASES.exists(r => relSt.get(r) == Active))
  // A properly reviewed release that changes a model is refused only because
  // that model's validation expired, was withdrawn, or has an open breach.
  val notRefusedByGateAlone = not(RELEASES.exists(r => refusal.get(r) == GateCause))
}

module gate {
  import release_gate(
    RELEASES = Set(1, 2),
    MODELS = Set("m1", "m2"),
    USERS = Set("alice", "bob", "carol", "dave"),
    VALIDATORS = Set("bob", "carol", "dave"),
    OWNER = Map("m1" -> "alice", "m2" -> "bob"),
    FIRST_AUTHOR = Map("m1" -> "bob", "m2" -> "alice"),
    MUTANT = ""
  ).*
}

module gate_mutant_all_models {
  import release_gate(
    RELEASES = Set(1, 2),
    MODELS = Set("m1", "m2"),
    USERS = Set("alice", "bob", "carol", "dave"),
    VALIDATORS = Set("bob", "carol", "dave"),
    OWNER = Map("m1" -> "alice", "m2" -> "bob"),
    FIRST_AUTHOR = Map("m1" -> "bob", "m2" -> "alice"),
    MUTANT = "all_models"
  ).*
}

module gate_mutant_no_gate {
  import release_gate(
    RELEASES = Set(1, 2),
    MODELS = Set("m1", "m2"),
    USERS = Set("alice", "bob", "carol", "dave"),
    VALIDATORS = Set("bob", "carol", "dave"),
    OWNER = Map("m1" -> "alice", "m2" -> "bob"),
    FIRST_AUTHOR = Map("m1" -> "bob", "m2" -> "alice"),
    MUTANT = "no_gate"
  ).*
}

module gate_mutant_no_supersede {
  import release_gate(
    RELEASES = Set(1, 2),
    MODELS = Set("m1", "m2"),
    USERS = Set("alice", "bob", "carol", "dave"),
    VALIDATORS = Set("bob", "carol", "dave"),
    OWNER = Map("m1" -> "alice", "m2" -> "bob"),
    FIRST_AUTHOR = Map("m1" -> "bob", "m2" -> "alice"),
    MUTANT = "no_supersede"
  ).*
}

module gate_mutant_no_review {
  import release_gate(
    RELEASES = Set(1, 2),
    MODELS = Set("m1", "m2"),
    USERS = Set("alice", "bob", "carol", "dave"),
    VALIDATORS = Set("bob", "carol", "dave"),
    OWNER = Map("m1" -> "alice", "m2" -> "bob"),
    FIRST_AUTHOR = Map("m1" -> "bob", "m2" -> "alice"),
    MUTANT = "no_review"
  ).*
}
