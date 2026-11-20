# Ledger throughput through Ash (D-072 point 3). Run with `veridian-ledger-bench`.
# Throwaway cluster, fsync off, synchronous_commit off (see devenv.nix): this
# measures the Elixir/Ash path and Postgres CPU, not durable commits.
alias Veridian.{Id, Ledger, Repo}

n = String.to_integer(System.get_env("N", "4000"))
bundle = String.to_integer(System.get_env("BUNDLE", "100"))
as_of = ~U[2026-11-20 00:00:00.000000Z]

calc = fn tag, i -> Id.new!(:calc, :sha256_v1, :crypto.hash(:sha256, "#{tag}-calc-#{i}")) end
result = fn i -> Id.new!(:result, :sha256_v1, :crypto.hash(:sha256, "result-#{i}")) end

time = fn label, count, fun ->
  {us, value} = :timer.tc(fun)
  rate = count / (us / 1_000_000)
  IO.puts("#{String.pad_trailing(label, 44)} #{String.pad_leading(to_string(count), 7)} in #{Float.round(us / 1_000_000, 2)} s = #{round(rate)} per s")
  value
end

Ecto.Adapters.SQL.query!(Repo, "TRUNCATE ledger_steps, ledger_requests, ledger_nodes", [])
IO.puts("N=#{n} bundle=#{bundle} (one step and one node per position)")

prep = fn ->
  for i <- 1..n do
    {req, step} = {Ecto.UUID.generate(), Ecto.UUID.generate()}
    {:ok, :ok} = Ledger.submit(req, %{step => []})
    {i, step}
  end
end

steps = time.("submit request+step", n, fn -> prep.() end)
time.("bind, creates the node", n, fn -> for {i, s} <- steps, do: {:ok, :created} = Ledger.bind(s, calc.(:a, i), as_of) end)
time.("dispatch", n, fn -> for {i, _} <- steps, do: {:ok, :ok} = Ledger.dispatch(calc.(:a, i)) end)

pairs = for {i, _} <- steps, do: {calc.(:a, i), result.(i)}
time.("complete_bundle, one committer", n, fn ->
  for b <- Enum.chunk_every(pairs, bundle), do: {:ok, :ok} = Ledger.complete_bundle(b)
end)

# Parallel committers on a second set of nodes (distinct nodes, so no waiting).
steps2 = prep.()
par = fn list, fun ->
  list
  |> Task.async_stream(fun, max_concurrency: 8, timeout: :infinity)
  |> Enum.each(fn {:ok, _} -> :ok end)
end

time.("bind, creates the node, 8 callers at once", n, fn ->
  par.(steps2, fn {i, s} -> {:ok, :created} = Ledger.bind(s, calc.(:b, i), as_of) end)
end)

for {i, _} <- steps2, do: {:ok, :ok} = Ledger.dispatch(calc.(:b, i))
pairs2 = for {i, _} <- steps2, do: {calc.(:b, i), result.(i)}

time.("complete_bundle, 8 committers at once", n, fn ->
  pairs2
  |> Enum.chunk_every(bundle)
  |> Task.async_stream(&Ledger.complete_bundle/1, max_concurrency: 8, timeout: :infinity)
  |> Enum.each(fn {:ok, {:ok, :ok}} -> :ok end)
end)

# Memo hits: new steps meeting complete nodes (they finish at once).
steps3 = prep.()
time.("bind, memo hit on a complete node", n, fn ->
  for {{i, _}, {_, s}} <- Enum.zip(steps, steps3), do: {:ok, :existing} = Ledger.bind(s, calc.(:a, i), as_of)
end)

steps4 = prep.()

time.("bind, memo hit, 8 callers at once", n, fn ->
  par.(Enum.zip(steps, steps4), fn {{i, _}, {_, s}} ->
    {:ok, :existing} = Ledger.bind(s, calc.(:a, i), as_of)
  end)
end)

# The realistic shape: ONE request with n independent steps (an end-of-day run),
# 8 workers each taking a bundle: bind every step (creating its node), dispatch
# the bundle, commit it in one transaction, finish its steps. Everything a node
# costs the ledger, per node.
big_req = Ecto.UUID.generate()
big_ids = for _ <- 1..n, do: Ecto.UUID.generate()
time.("submit ONE request with n steps (row by row)", n, fn ->
  {:ok, :ok} = Ledger.submit(big_req, Map.new(big_ids, &{&1, []}))
end)

big = big_ids |> Enum.with_index() |> Enum.chunk_every(bundle)

time.("full path per node, 1 request, 8 workers", n, fn ->
  par.(big, fn chunk ->
    for {s, i} <- chunk, do: {:ok, :created} = Ledger.bind(s, calc.(:big, i), as_of)
    for {_, i} <- chunk, do: {:ok, :ok} = Ledger.dispatch(calc.(:big, i))
    {:ok, :ok} = Ledger.complete_bundle(for {_, i} <- chunk, do: {calc.(:big, i), result.(i)})
    for {s, _} <- chunk, do: {:ok, :ok} = Ledger.step_done(s)
  end)
end)

bundled_req = Ecto.UUID.generate()
bundled_ids = for _ <- 1..n, do: Ecto.UUID.generate()

time.("submit ONE request with n steps (bulk)", n, fn ->
  {:ok, :ok} = Ledger.submit(bundled_req, Map.new(bundled_ids, &{&1, []}))
end)

time.("full path per node, BUNDLED calls, 8 workers", n, fn ->
  bundled_ids
  |> Enum.with_index()
  |> Enum.chunk_every(bundle)
  |> par.(fn chunk ->
    c = fn i -> calc.(:bun, i) end
    {:ok, _} = Ledger.bind_bundle(for {s, i} <- chunk, do: {s, c.(i), as_of})
    {:ok, :ok} = Ledger.dispatch_bundle(for {_, i} <- chunk, do: c.(i))
    {:ok, :ok} = Ledger.complete_bundle(for {_, i} <- chunk, do: {c.(i), result.(i)})
    {:ok, :ok} = Ledger.step_done_bundle(for {s, _} <- chunk, do: s)
  end)
end)

time.("same, memo hits, BUNDLED bind, 8 workers", n, fn ->
  req = Ecto.UUID.generate()
  ids = for _ <- 1..n, do: Ecto.UUID.generate()
  {:ok, :ok} = Ledger.submit(req, Map.new(ids, &{&1, []}))

  ids
  |> Enum.with_index()
  |> Enum.chunk_every(bundle)
  |> par.(fn chunk ->
    {:ok, kinds} = Ledger.bind_bundle(for {s, i} <- chunk, do: {s, calc.(:big, i), as_of})
    true = Enum.all?(kinds, &(&1 == :existing))
  end)
end)

time.("same, memo hits (a second request, same calc_ids)", n, fn ->
  req = Ecto.UUID.generate()
  ids = for _ <- 1..n, do: Ecto.UUID.generate()
  {:ok, :ok} = Ledger.submit(req, Map.new(ids, &{&1, []}))

  ids
  |> Enum.with_index()
  |> Enum.chunk_every(bundle)
  |> par.(fn chunk ->
    for {s, i} <- chunk do
      {:ok, :existing} = Ledger.bind(s, calc.(:big, i), as_of)
      # A memo hit finishes at once with the node's result: the step is done.
    end
  end)
end)

# Raw lookup latency, one process, random existing calc_id.
ids = for {i, _} <- steps, do: calc.(:a, i)
samples = for _ <- 1..5000, do: elem(:timer.tc(fn -> Ledger.lookup(Enum.random(ids)) end), 0)
sorted = Enum.sort(samples)
pct = fn p -> Enum.at(sorted, round(p / 100 * (length(sorted) - 1))) / 1000 end
IO.puts("lookup by calc_id (Ash read), 5000 samples: p50 #{Float.round(pct.(50), 2)} ms, p99 #{Float.round(pct.(99), 2)} ms")
