# The code gate: the Elixir control plane (Ash, PostgreSQL) and the Julia
# canonical-form package, with their tests, Dialyzer, the Quint trace fixtures
# and the ledger measurements. Imported by devenv.nix in this repository and by
# the release tree, so both run the same checks (D-083).
{ pkgs, ... }:
let
  # A throwaway PostgreSQL cluster for the ledger tests and benchmark. Its data
  # directory is outside the source tree (a file-sync tool scanning it would
  # distort I/O), it listens on a unix socket only, trades durability for speed
  # (fsync off: tests check behaviour, not crash safety) and keeps memory small.
  # It is stopped when the script exits, however it exits.
  pgTestCluster = ''
    state="$HOME/.local/state/veridian-test"
    pgdata="$state/pg"
    mkdir -p "$state"
    export VERIDIAN_PG_SOCKET_DIR="$state"
    export VERIDIAN_PG_PORT=55432
    if [ ! -d "$pgdata" ]; then
      initdb -D "$pgdata" --locale=C --encoding=UTF8 -A trust > /dev/null
    fi
    # VERIDIAN_PG_DURABLE=1 keeps fsync, synchronous commit and full-page writes
    # on, to measure real commits (veridian-ledger-bench-durable).
    if [ "''${VERIDIAN_PG_DURABLE:-0}" = 1 ]; then
      dur="-c fsync=on -c synchronous_commit=on -c full_page_writes=on"
    else
      dur="-c fsync=off -c synchronous_commit=off -c full_page_writes=off"
    fi
    if ! pg_ctl -D "$pgdata" status > /dev/null 2>&1; then
      pg_ctl -D "$pgdata" -w -l "$state/pg.log" \
        -o "-c listen_addresses= -c unix_socket_directories=$state -c port=$VERIDIAN_PG_PORT \
            $dur -c shared_buffers=128MB -c max_connections=60" start > /dev/null
    fi
    trap 'pg_ctl -D "$pgdata" -m fast stop > /dev/null 2>&1 || true' EXIT
  '';

  # devenv gives each checkout its own MIX_HOME. Seed Hex and rebar3 from the
  # user's copies so a fresh checkout does not reinstall them. Dependencies come
  # from the local Hex cache (~/.hex); a package missing from it (or at another
  # version than mix.lock) is fetched once from hex.pm and cached.
  seedMixHome = ''
    if [ ! -d "$MIX_HOME/archives" ] && [ -d "$HOME/.mix/archives" ]; then
      mkdir -p "$MIX_HOME"
      cp -r "$HOME/.mix/archives" "$MIX_HOME/archives"
      [ -d "$HOME/.mix/elixir" ] && cp -r "$HOME/.mix/elixir" "$MIX_HOME/elixir"
    fi
  '';

  # A fresh database every run, so the migrations are always tested from zero.
  freshDb = ''
    mix ash_postgres.drop --quiet
    mix ash_postgres.create --quiet
    mix ash_postgres.migrate --quiet
  '';
in
{
  # The ledger's database (D-014): the scripts run their own throwaway cluster;
  # there is no always-on service.
  packages = [ pkgs.postgresql ];

  languages = {
    elixir = {
      enable = true;
      directory = "./control_plane";
    };
    julia.enable = true;
  };

  # The local test gate (D-049): run it before every commit that touches
  # control_plane/. Elixir's type checker reports through compiler warnings,
  # which are errors here. Nice 10 so it does not starve a desktop.
  scripts.veridian-test.exec = ''
    set -eu
    cd "$DEVENV_ROOT/control_plane"
    export MIX_ENV=test
    ${pgTestCluster}
    ${seedMixHome}
    nice -n 10 mix deps.get --check-locked 2>/dev/null || nice -n 10 mix deps.get
    nice -n 10 mix format --check-formatted
    nice -n 10 mix compile --force --warnings-as-errors
    # Ash owns the schema (D-080): the migrations must be what the resources say.
    nice -n 10 mix ash.codegen --check
    ${freshDb}
    nice -n 10 mix test
  '';

  # Dialyzer over the control plane (D-076). The first run builds the PLTs (Ash
  # and its dependencies; several minutes), later runs take seconds. Not part of
  # veridian-test because of that first run.
  scripts.veridian-dialyzer.exec = ''
    set -eu
    cd "$DEVENV_ROOT/control_plane"
    export MIX_ENV=test
    ${seedMixHome}
    nice -n 10 mix deps.get
    nice -n 10 mix dialyzer
  '';

  # The canonical-form and hash package (D-075, D-082): frozen vectors from the
  # independent Python generator, property tests, Aqua and JET.
  scripts.veridian-julia-test.exec = ''
    set -eu
    cd "$DEVENV_ROOT/julia/VeridianCanonical"
    julia --project=test -e 'using Pkg; Pkg.instantiate()'
    julia --project=test test/runtests.jl
  '';

  # Regenerates the Quint traces the control plane replays (D-059): random runs
  # with action names (--mbt, fixed seed) and the model's scenarios. Commit the
  # result only when the model changes.
  scripts.veridian-traces.exec = ''
    set -eu
    cd "$DEVENV_ROOT"
    out=control_plane/fixtures/traces
    mkdir -p "$out/calc_graph" "$out/calc_graph_scenarios"
    find "$out/calc_graph" "$out/calc_graph_scenarios" -name '*.itf.json' -delete
    quint run models/calc_graph_instances.qnt --main=calc_graph_fixed \
      --max-steps=40 --max-samples=200 --n-traces=20 --seed=20261120 \
      --out-itf="$out/calc_graph/trace_{seq}.itf.json" --mbt > /dev/null
    tmp="$(mktemp -d)"
    quint test models/calc_graph_scenarios.qnt --main=calc_graph_fixed \
      --out-itf="$tmp/{test}.itf.json" > /dev/null
    for f in "$tmp"/*.itf.json; do
      n="''${f##*::}"
      cp "$f" "$out/calc_graph_scenarios/$n"
    done
    rm -r "$tmp"
    # The traces are valid for exactly these model files; a test compares.
    # Bytewise file order, as the test sorts them (the shell glob is locale-sorted).
    ls models/calc_graph*.qnt | LC_ALL=C sort | xargs cat | sha256sum | cut -d' ' -f1 \
      > "$out/calc_graph.models.sha256"
  '';

  # Ledger measurements (D-073, D-078, D-079): not part of any gate. Wall time
  # on a shared machine is not to be trusted; veridian-ledger-cost reports counts
  # and CPU time instead.
  scripts.veridian-ledger-bench.exec = ''
    set -eu
    cd "$DEVENV_ROOT/control_plane"
    export MIX_ENV=test
    ${pgTestCluster}
    ${freshDb}
    mix run bench/ledger_bench.exs
  '';

  scripts.veridian-ledger-cost.exec = ''
    set -eu
    cd "$DEVENV_ROOT/control_plane"
    export MIX_ENV=test
    ${pgTestCluster}
    ${freshDb}
    mix run bench/ledger_cost.exs
  '';

  # Durable commits (fsync and synchronous commit on): the figure the 1,000
  # nodes/s target is judged on (D-044). Bundle calls only.
  scripts.veridian-ledger-bench-durable.exec = ''
    set -eu
    cd "$DEVENV_ROOT/control_plane"
    export MIX_ENV=test
    export VERIDIAN_PG_DURABLE=1
    ${pgTestCluster}
    ${freshDb}
    mix run bench/ledger_bench_durable.exs
  '';
}
