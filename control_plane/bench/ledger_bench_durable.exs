# The bundled ledger path with durable commits (D-078). Run with
# `veridian-ledger-bench-durable`, which starts the throwaway cluster with fsync
# and synchronous commit on. Each bundle costs four commits (bind, dispatch,
# complete, finish), so this reports commits per second too.
alias Veridian.{Id, Ledger, Repo}

n = String.to_integer(System.get_env("N", "4000"))
bundle = String.to_integer(System.get_env("BUNDLE", "100"))
workers = String.to_integer(System.get_env("WORKERS", "8"))
as_of = ~U[2026-11-20 00:00:00.000000Z]

calc = fn i -> Id.new!(:calc, :sha256_v1, :crypto.hash(:sha256, "durable-calc-#{i}")) end
result = fn i -> Id.new!(:result, :sha256_v1, :crypto.hash(:sha256, "durable-result-#{i}")) end

Ecto.Adapters.SQL.query!(Repo, "TRUNCATE ledger_steps, ledger_requests, ledger_nodes", [])

%{rows: [[fsync]]} = Ecto.Adapters.SQL.query!(Repo, "SHOW fsync", [])
%{rows: [[sync]]} = Ecto.Adapters.SQL.query!(Repo, "SHOW synchronous_commit", [])
IO.puts("fsync=#{fsync} synchronous_commit=#{sync} N=#{n} bundle=#{bundle} workers=#{workers}")

par = fn list, fun ->
  list
  |> Task.async_stream(fun, max_concurrency: workers, timeout: :infinity)
  |> Enum.each(fn {:ok, _} -> :ok end)
end

req = Ecto.UUID.generate()
ids = for _ <- 1..n, do: Ecto.UUID.generate()
{:ok, :ok} = Ledger.submit(req, Map.new(ids, &{&1, []}))
chunks = ids |> Enum.with_index() |> Enum.chunk_every(bundle)

{us, _} =
  :timer.tc(fn ->
    par.(chunks, fn chunk ->
      {:ok, _} = Ledger.bind_bundle(for {s, i} <- chunk, do: {s, calc.(i), as_of})
      {:ok, :ok} = Ledger.dispatch_bundle(for {_, i} <- chunk, do: calc.(i))
      {:ok, :ok} = Ledger.complete_bundle(for {_, i} <- chunk, do: {calc.(i), result.(i)})
      {:ok, :ok} = Ledger.step_done_bundle(for {s, _} <- chunk, do: s)
    end)
  end)

secs = us / 1_000_000
commits = length(chunks) * 4
IO.puts("whole path, durable: #{n} nodes in #{Float.round(secs, 2)} s = #{round(n / secs)} nodes/s (#{commits} commits, #{round(commits / secs)} per s)")

req2 = Ecto.UUID.generate()
ids2 = for _ <- 1..n, do: Ecto.UUID.generate()
{:ok, :ok} = Ledger.submit(req2, Map.new(ids2, &{&1, []}))

{us2, _} =
  :timer.tc(fn ->
    ids2
    |> Enum.with_index()
    |> Enum.chunk_every(bundle)
    |> par.(fn chunk ->
      {:ok, kinds} = Ledger.bind_bundle(for {s, i} <- chunk, do: {s, calc.(i), as_of})
      true = Enum.all?(kinds, &(&1 == :existing))
    end)
  end)

secs2 = us2 / 1_000_000
IO.puts("memo hits, bundled bind, durable: #{n} nodes in #{Float.round(secs2, 2)} s = #{round(n / secs2)} nodes/s")
