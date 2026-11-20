# Cost of the bundled ledger path that does not depend on how busy the machine
# is (D-079): statements and commits per node, and CPU time of the BEAM and of
# the database processes per node. Wall time is printed but must not be trusted
# when other processes compete for the machine. Run with `veridian-ledger-cost`.
alias Veridian.{Id, Ledger, Repo}

n = String.to_integer(System.get_env("N", "4000"))
bundle = String.to_integer(System.get_env("BUNDLE", "100"))
workers = String.to_integer(System.get_env("WORKERS", "4"))
as_of = ~U[2026-11-20 00:00:00.000000Z]

calc = fn i -> Id.new!(:calc, :sha256_v1, :crypto.hash(:sha256, "cost-calc-#{i}")) end
result = fn i -> Id.new!(:result, :sha256_v1, :crypto.hash(:sha256, "cost-result-#{i}")) end

Ecto.Adapters.SQL.query!(Repo, "TRUNCATE ledger_steps, ledger_requests, ledger_nodes", [])

# Counters: 1 = statements (all queries seen by the Repo), 2 = commits.
counters = :counters.new(2, [:atomics])

:telemetry.attach(
  "ledger-cost",
  [:veridian, :repo, :query],
  fn _event, _measure, meta, _config ->
    :counters.add(counters, 1, 1)
    if String.downcase(to_string(meta.query)) == "commit", do: :counters.add(counters, 2, 1)
  end,
  nil
)

# CPU seconds of the database server's processes, from /proc (clock ticks).
pg_pid =
  Path.join([System.user_home!(), ".local/state/veridian-test/pg/postmaster.pid"])
  |> File.read!()
  |> String.split("\n")
  |> hd()
  |> String.to_integer()

pg_cpu_ticks = fn ->
  for dir <- Path.wildcard("/proc/[0-9]*"), reduce: 0 do
    acc ->
      with {:ok, stat} <- File.read(Path.join(dir, "stat")),
           [_, rest] <- String.split(stat, ") ", parts: 2),
           [_state, ppid | fields] <- String.split(rest),
           true <- String.to_integer(ppid) == pg_pid or Path.basename(dir) == "#{pg_pid}" do
        # utime and stime are fields 14 and 15 of stat: indexes 11 and 12 here.
        acc + String.to_integer(Enum.at(fields, 9)) + String.to_integer(Enum.at(fields, 10))
      else
        _ -> acc
      end
  end
end

par = fn list, fun ->
  list
  |> Task.async_stream(fun, max_concurrency: workers, timeout: :infinity)
  |> Enum.each(fn {:ok, _} -> :ok end)
end

req = Ecto.UUID.generate()
ids = for _ <- 1..n, do: Ecto.UUID.generate()
{:ok, :ok} = Ledger.submit(req, Map.new(ids, &{&1, []}))
chunks = ids |> Enum.with_index() |> Enum.chunk_every(bundle)

:erlang.statistics(:runtime)
pg0 = pg_cpu_ticks.()
q0 = :counters.get(counters, 1)
c0 = :counters.get(counters, 2)
t0 = System.monotonic_time(:millisecond)

par.(chunks, fn chunk ->
  {:ok, _} = Ledger.bind_bundle(for {s, i} <- chunk, do: {s, calc.(i), as_of})
  {:ok, :ok} = Ledger.dispatch_bundle(for {_, i} <- chunk, do: calc.(i))
  {:ok, :ok} = Ledger.complete_bundle(for {_, i} <- chunk, do: {calc.(i), result.(i)})
  {:ok, :ok} = Ledger.step_done_bundle(for {s, _} <- chunk, do: s)
end)

{_, beam_ms} = :erlang.statistics(:runtime)
wall_ms = System.monotonic_time(:millisecond) - t0
pg_ms = (pg_cpu_ticks.() - pg0) * 10
queries = :counters.get(counters, 1) - q0
commits = :counters.get(counters, 2) - c0
bundles = length(chunks)

f = fn x -> Float.round(x, 1) end

IO.puts("""
N=#{n} bundle=#{bundle} workers=#{workers}  (#{bundles} bundles)
statements per bundle: #{f.(queries / bundles)}   commits per bundle: #{f.(commits / bundles)}
CPU per node: BEAM #{f.(beam_ms * 1000 / n)} us, database #{f.(pg_ms * 1000 / n)} us, total #{f.((beam_ms + pg_ms) * 1000 / n)} us
(wall #{wall_ms} ms: not to be trusted on a shared machine)
""")
