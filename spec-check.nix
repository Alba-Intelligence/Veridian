# The specification gate (D-055): Allium CLI, Quint, and the two check scripts.
# Imported by devenv.nix in this repository and by the release tree, so both
# run the same checks.
{
  pkgs,
  inputs,
  ...
}:
let
  naerskLib = pkgs.callPackage inputs.naersk { };

  # Allium CLI, built from the crates.io release.
  alliumCli =
    let
      version = "3.6.1";
      crate = pkgs.fetchurl {
        url = "https://static.crates.io/crates/allium-cli/allium-cli-${version}.crate";
        hash = "sha256-ammBpia6zj0nmeKOC0eYWeF52Ji5ZF6/pRSz05uuUew=";
      };
    in
    naerskLib.buildPackage {
      pname = "allium-cli";
      inherit version;
      src = pkgs.runCommand "allium-cli-${version}-src" { } ''
        mkdir -p "$out"
        tar -xzf ${crate} -C "$out" --strip-components=1
      '';
      singleStep = true;
    };
in
{
  packages = [
    alliumCli

    # Executable protocol models (Quint, TLA+ semantics): `quint run`
    # simulates offline; `quint verify` also needs Apalache, which nixpkgs
    # does not package (it is fetched on first use).
    pkgs.quint
  ];

  # Typechecks the Quint models under models/ and simulates their invariants.
  # VERIDIAN_QUINT_RUNS (default 20000) is the number of random runs per check.
  scripts.veridian-quint-check.exec = ''
    set -eu
    runs="''${VERIDIAN_QUINT_RUNS:-20000}"
    # run <model file> <instance> <property>: succeeds when no violation is found.
    run() { quint run "models/$1.qnt" --main="$2" --invariant="$3" \
      --max-samples="$runs" --max-steps=60 --verbosity=1; }
    # must_hold / must_fail: the second is a negative control or a witness.
    must_hold() { run "$@"; }
    must_fail() {
      if run "$@"; then echo "UNEXPECTED: no violation of $3 in $2"; exit 1; fi
    }
    # must_fail_test <model file> <instance> <scenario>: the scenario must fail.
    must_fail_test() {
      if quint test "models/$1.qnt" --main="$2" --match="$3" > /dev/null 2>&1; then
        echo "UNEXPECTED: scenario $3 passes in $2"; exit 1
      fi
    }
    for m in models/*.qnt; do
      quint typecheck "$m"
    done

    # Bundled dispatch (spec 07). Without the reap the stranded report appears
    # again, so the property has teeth; some run settles every node.
    must_hold bundled_dispatch dispatch safety
    must_hold bundled_dispatch dispatch noOrphanedReport
    must_fail bundled_dispatch dispatch_mutant_no_reap noOrphanedReport
    must_fail bundled_dispatch dispatch notAllSettled

    # Release gate (specs 05, 21). Each mutant removes one control or reverts a
    # decision and must break the property that guards it (all_models: D-058,
    # a release that changes no model is never refused by the model gate).
    # The last two are witnesses: a release can be activated, and a release
    # that changes a model can be refused by the model gate alone.
    must_hold release_gate gate safety
    must_fail release_gate gate_mutant_no_gate gateHeldAtActivation
    must_fail release_gate gate_mutant_no_supersede oneActive
    must_fail release_gate gate_mutant_no_review reviewedProduction
    must_fail release_gate gate_mutant_all_models noGateRefusalWithoutChange
    must_fail release_gate gate notActivated
    must_fail release_gate gate notRefusedByGateAlone
    # Calculation graph (spec 02, D-061, D-062). The fixed instance is the
    # behaviour. Each mutant removes one control: no_stampede is caught by a
    # property in random runs; dup_remat and remat_broken (spec 02 as written
    # before D-062) need about 20 steps, so each must fail its own scenario.
    # Witnesses must be violated.
    must_hold calc_graph calc_graph_fixed safety
    must_fail calc_graph calc_graph_mutant_no_stampede oneInFlight
    must_fail calc_graph calc_graph_fixed notUnfulfilled
    must_fail calc_graph calc_graph_fixed notMemoHit
    must_fail calc_graph calc_graph_fixed notAttached
    must_fail calc_graph calc_graph_fixed notRematerialised
    must_fail calc_graph calc_graph_fixed notRetried
    must_fail calc_graph calc_graph_fixed notFailedNode
    quint test models/calc_graph.qnt --main=calc_graph_fixed
    must_fail_test calc_graph calc_graph_mutant_dup_remat purgedTwiceTest
    must_fail_test calc_graph calc_graph_mutant_remat_broken brokenNodeTest
    echo "models: all checks as expected"
  '';

  # The check required before every commit that touches a spec or a model
  # (D-055): Allium check, traceability both ways, then the model checks.
  scripts.veridian-spec-check.exec = ''
    set -eu
    out="$(mktemp)"
    allium check specs/*.allium > "$out" || true
    if grep -q '"severity": "error"' "$out"; then
      echo "allium check: errors, see $out"; exit 1
    fi
    echo "allium check: no errors"
    models/trace_check.sh
    veridian-quint-check
  '';
}
