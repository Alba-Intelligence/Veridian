defmodule Veridian.Test.CalcGraphLedgerAdapter do
  @moduledoc """
  The same model actions as `Veridian.Test.CalcGraphAdapter`, applied to the
  PostgreSQL ledger (`Veridian.Ledger`) instead of the pure state machine, with
  the database projected back to the model's variables. Test support.

  The model's integers are mapped to real identifiers: a node `n` is the calc_id
  `sha256("node-n")`, a result hash `h` the result id `sha256("result-h")`, a
  request or step a UUID from a hash. The database is mutable, so the state
  passed around is just `:db`; `try_action/3` runs an action in a transaction
  that it rolls back.
  """

  alias Veridian.{Id, Ledger, Repo}
  alias Veridian.Test.CalcGraphAdapter, as: Pure

  @reqs [1, 2, 3]
  @input %{1 => 1, 2 => 2, 3 => 1}
  @result %{1 => 7, 2 => 7}
  @nodes [1, 2, 107]
  @results [7, 1107]
  @steps for r <- @reqs, k <- [0, 1], do: {r, k}
  @as_of ~U[2026-11-20 00:00:00.000000Z]

  defp hash(tag, x), do: :crypto.hash(:sha256, "#{tag}-#{inspect(x)}")

  defp uuid(tag, x) do
    {:ok, s} = Ecto.UUID.load(binary_part(hash(tag, x), 0, 16))
    s
  end

  defp node_id(n), do: Id.new!(:calc, :sha256_v1, hash(:node, n))
  defp result_id(h), do: Id.new!(:result, :sha256_v1, hash(:result, h))
  defp req_uuid(r), do: uuid(:req, r)
  defp step_uuid(r, k), do: uuid(:step, {r, k})

  @spec init() :: :db
  def init do
    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE ledger_steps, ledger_requests, ledger_nodes", [])
    :db
  end

  defdelegate candidates(), to: Pure
  defdelegate model_view(state), to: Pure

  @spec apply_action!(:db, String.t(), map()) :: :db
  def apply_action!(:db, "init", _), do: :db

  def apply_action!(:db, "submit", %{r: r}) do
    ok!(
      Ledger.submit(req_uuid(r), %{
        step_uuid(r, 0) => [],
        step_uuid(r, 1) => [step_uuid(r, 0)]
      })
    )
  end

  def apply_action!(:db, "bindNew", %{r: r, k: k}), do: bind!(r, k, :created)
  def apply_action!(:db, "bindExisting", %{r: r, k: k}), do: bind!(r, k, :existing)
  def apply_action!(:db, "dispatch", %{n: n}), do: ok!(Ledger.dispatch(node_id(n)))

  def apply_action!(:db, "succeed", %{n: n}),
    do: ok!(Ledger.complete_bundle([{node_id(n), result_id(compute_result(n))}]))

  def apply_action!(:db, "crash", %{n: n}), do: ok!(Ledger.crash(node_id(n)))
  def apply_action!(:db, "reject", %{n: n}), do: ok!(Ledger.reject(node_id(n)))
  def apply_action!(:db, "cool", %{n: n}), do: ok!(Ledger.cool(node_id(n)))
  def apply_action!(:db, "purge", %{n: n}), do: ok!(Ledger.purge(node_id(n)))

  def apply_action!(:db, "rematAnswer", %{n: n, same: same}),
    do: ok!(Ledger.remat_answer(node_id(n), same))

  def apply_action!(:db, "rematCrash", %{n: n}), do: ok!(Ledger.remat_crash(node_id(n)))
  def apply_action!(:db, "rerun", %{n: n}), do: ok!(Ledger.rerun(node_id(n)))
  def apply_action!(:db, "stepDone", %{r: r, k: k}), do: ok!(Ledger.step_done(step_uuid(r, k)))

  def apply_action!(:db, "stepAbandon", %{r: r, k: k}),
    do: ok!(Ledger.step_abandon(step_uuid(r, k)))

  def apply_action!(:db, "requestFulfil", %{r: r}), do: ok!(Ledger.request_fulfil(req_uuid(r)))
  def apply_action!(:db, "requestFail", %{r: r}), do: ok!(Ledger.request_fail(req_uuid(r)))
  def apply_action!(:db, "cancel", %{r: r}), do: ok!(Ledger.cancel(req_uuid(r)))

  def apply_action!(:db, "stepCancel", %{r: r, k: k}),
    do: ok!(Ledger.step_cancel(step_uuid(r, k)))

  defp bind!(r, k, expected) do
    n = node_int(r, k)

    case Ledger.bind(step_uuid(r, k), node_id(n), @as_of) do
      {:ok, ^expected} -> :db
      {:ok, other} -> raise "bind(#{r},#{k}): model took #{expected}, ledger did #{other}"
      {:error, reason} -> raise "bind(#{r},#{k}) refused: #{inspect(reason)}"
    end
  end

  # The model's idOf: A from its input, B from the result hash of A's node.
  defp node_int(r, 0), do: Map.fetch!(@input, r)

  defp node_int(r, 1) do
    case Ledger.step_result_hash(step_uuid(r, 0)) do
      {:ok, id} -> 100 + Map.fetch!(rev_results(), id)
      {:error, reason} -> raise "no calc_id for step (#{r},1) yet: #{inspect(reason)}"
    end
  end

  defp compute_result(n) when n < 100, do: Map.fetch!(@result, n)
  defp compute_result(n), do: n + 1000

  defp ok!({:ok, _}), do: :db
  defp ok!({:error, reason}), do: raise("refused: #{inspect(reason)}")

  @doc "The projection `action` would give; its effect is rolled back."
  @spec try_action(:db, String.t(), map()) :: {:ok, map()} | :error
  def try_action(:db, action, picks) do
    outcome =
      Repo.transaction(fn ->
        try do
          apply_action!(:db, action, picks)
          Repo.rollback({:projection, project(:db)})
        rescue
          _ -> Repo.rollback(:refused)
        end
      end)

    case outcome do
      {:error, {:projection, p}} -> {:ok, p}
      _ -> :error
    end
  end

  @doc "The model's variables read back from the database."
  @spec project(:db) :: map()
  def project(:db) do
    g = Ledger.snapshot()

    translated = %{
      g
      | requests: Map.new(g.requests, fn {k, v} -> {Map.fetch!(rev_reqs(), k), v} end),
        steps:
          Map.new(g.steps, fn {k, s} ->
            {Map.fetch!(rev_steps(), k), %{s | node: s.node && Map.fetch!(rev_nodes(), s.node)}}
          end),
        nodes:
          Map.new(g.nodes, fn {k, n} ->
            rh = n.result_hash && Map.fetch!(rev_results(), n.result_hash)
            {Map.fetch!(rev_nodes(), k), %{n | result_hash: rh}}
          end)
    }

    Pure.project(translated)
  end

  defp rev_reqs, do: Map.new(@reqs, &{req_uuid(&1), &1})
  defp rev_steps, do: Map.new(@steps, fn {r, k} -> {step_uuid(r, k), {r, k}} end)
  defp rev_nodes, do: Map.new(@nodes, &{node_id(&1), &1})
  defp rev_results, do: Map.new(@results, &{result_id(&1), &1})
end
