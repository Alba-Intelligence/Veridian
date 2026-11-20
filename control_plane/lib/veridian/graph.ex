defmodule Veridian.Graph do
  @moduledoc """
  The calculation graph's ledger rules as a pure state machine (spec 02, 02b,
  02c; model `models/calc_graph.qnt`, D-061, D-062, D-063).

  State is plain data and every function is one **atomic ledger step**: it
  returns `{:ok, new_state}` or `{:error, reason}` and never touches a
  database, clock or worker. The Postgres ledger (later increment) must apply
  each step in one transaction; that is the requirement the model fixes
  ("binding a step is one atomic ledger step"). The Quint model is
  authoritative for this behaviour (D-055); `test/veridian/graph_replay_test.exs`
  replays the model's traces against this module (D-059).

  Keys (`request`, `step`, `node`) are opaque terms chosen by the caller: a node
  is keyed by its calc_id (`Veridian.CalcId`). The caller computes a step's
  calc_id from its prerequisites' result hashes, see `step_result_hash/2`.

  Not covered here (as in the model): planning, bitemporal resolution, data
  classes, queue capacity, time (timeouts are `crash/2`), the worker protocol.
  """

  @type key :: term()
  @type request_status :: :open | :fulfilled | :unfulfilled
  @type step_status :: :waiting | :running | :done | :abandoned | :cancelled
  @type node_status :: :pending | :computing | :complete | :failed
  @type tier :: :hot | :cold | :purged

  @type req :: %{status: request_status()}
  @type step :: %{
          request: key(),
          prerequisites: [key()],
          status: step_status(),
          node: key() | nil
        }
  @type gnode :: %{
          status: node_status(),
          attempts: non_neg_integer(),
          result_hash: term() | nil,
          reproducible: boolean(),
          tier: tier() | nil,
          remat_in_flight: non_neg_integer(),
          remat_attempts: non_neg_integer()
        }
  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          requests: %{optional(key()) => req()},
          steps: %{optional(key()) => step()},
          nodes: %{optional(key()) => gnode()}
        }
  @type result :: {:ok, t()} | {:error, atom()}

  @enforce_keys [:max_attempts]
  defstruct [:max_attempts, requests: %{}, steps: %{}, nodes: %{}]

  @doc "An empty graph. `max_attempts` bounds node dispatches and recomputation dispatches."
  @spec new(pos_integer()) :: t()
  def new(max_attempts) when is_integer(max_attempts) and max_attempts > 0,
    do: %__MODULE__{max_attempts: max_attempts}

  # Requests -----------------------------------------------------------------

  @doc """
  AcceptCalculationRequest: a request opens with its planned steps waiting.
  `steps` maps each step key to the step keys it needs (its prerequisites).
  """
  @spec submit(t(), key(), %{optional(key()) => [key()]}) :: result()
  def submit(%__MODULE__{} = g, req, steps) when is_map(steps) do
    cond do
      Map.has_key?(g.requests, req) -> {:error, :request_exists}
      Enum.any?(steps, fn {s, _} -> Map.has_key?(g.steps, s) end) -> {:error, :step_exists}
      not prerequisites_inside?(steps) -> {:error, :unknown_prerequisite}
      true -> {:ok, add_request(g, req, steps)}
    end
  end

  defp prerequisites_inside?(steps),
    do: Enum.all?(steps, fn {_s, ps} -> Enum.all?(ps, &Map.has_key?(steps, &1)) end)

  defp add_request(g, req, steps) do
    new_steps =
      Map.new(steps, fn {s, ps} ->
        {s, %{request: req, prerequisites: ps, status: :waiting, node: nil}}
      end)

    %{
      g
      | requests: Map.put(g.requests, req, %{status: :open}),
        steps: Map.merge(g.steps, new_steps)
    }
  end

  @doc "RequestCompletes: every step of an open request is done."
  @spec request_fulfil(t(), key()) :: result()
  def request_fulfil(g, req) do
    with {:ok, :open} <- request_status(g, req),
         true <- steps_of(g, req) |> Enum.all?(&(&1.status == :done)) || {:error, :steps_not_done} do
      {:ok, put_in(g.requests[req].status, :fulfilled)}
    else
      {:ok, _} -> {:error, :request_not_open}
      {:error, _} = e -> e
    end
  end

  @doc "RequestFails: an open request with an abandoned step is unfulfilled."
  @spec request_fail(t(), key()) :: result()
  def request_fail(g, req) do
    with {:ok, :open} <- request_status(g, req),
         true <-
           steps_of(g, req) |> Enum.any?(&(&1.status == :abandoned)) ||
             {:error, :no_abandoned_step} do
      {:ok, put_in(g.requests[req].status, :unfulfilled)}
    else
      {:ok, _} -> {:error, :request_not_open}
      {:error, _} = e -> e
    end
  end

  @doc "CancelRequest: an open request becomes unfulfilled; running steps keep going."
  @spec cancel(t(), key()) :: result()
  def cancel(g, req) do
    case request_status(g, req) do
      {:ok, :open} -> {:ok, put_in(g.requests[req].status, :unfulfilled)}
      {:ok, _} -> {:error, :request_not_open}
      {:error, _} = e -> e
    end
  end

  @doc "StepCancelledWithRequest: a waiting step of an unfulfilled request is cancelled."
  @spec step_cancel(t(), key()) :: result()
  def step_cancel(g, step) do
    with {:ok, s} <- fetch_step(g, step),
         {:ok, :unfulfilled} <- request_status(g, s.request),
         :waiting <- s.status do
      {:ok, put_in(g.steps[step].status, :cancelled)}
    else
      {:error, _} = e -> e
      {:ok, _} -> {:error, :request_not_unfulfilled}
      _ -> {:error, :step_not_waiting}
    end
  end

  # Steps ----------------------------------------------------------------------

  @doc """
  The result hash of the node a step is bound to, for building a dependent
  step's calc_id (early cutoff: dependents see result hashes, not calc_ids).
  """
  @spec step_result_hash(t(), key()) :: {:ok, term()} | {:error, atom()}
  def step_result_hash(g, step) do
    with {:ok, %{node: n}} when n != nil <- fetch_step(g, step),
         %{result_hash: h} when h != nil <- g.nodes[n] do
      {:ok, h}
    else
      _ -> {:error, :no_result}
    end
  end

  @doc """
  StepBindsToNode: a ready step of an open request meets the node of `calc_id`.

  Returns `{:ok, g, :created | :existing}`. A new node is created pending; an
  existing one gives a memo hit (done), an attachment (running), a
  rematerialisation of a purged payload (running; one recomputation however
  many steps wait, D-062), or an inherited failure (abandoned; a failed or
  irreproducible node fails its steps at once).
  """
  @spec bind(t(), key(), key()) :: {:ok, t(), :created | :existing} | {:error, atom()}
  def bind(g, step, calc_id) do
    with {:ok, s} <- fetch_step(g, step),
         {:ok, :open} <- request_status(g, s.request),
         :waiting <- s.status,
         true <- ready?(g, s) || {:error, :not_ready} do
      case g.nodes do
        %{^calc_id => node} -> {:ok, bind_existing(g, step, calc_id, node), :existing}
        _ -> {:ok, bind_new(g, step, calc_id), :created}
      end
    else
      {:error, _} = e -> e
      {:ok, _} -> {:error, :request_not_open}
      _ -> {:error, :step_not_waiting}
    end
  end

  defp ready?(g, s), do: Enum.all?(s.prerequisites, &(g.steps[&1].status == :done))

  defp bind_new(g, step, id) do
    node = %{
      status: :pending,
      attempts: 0,
      result_hash: nil,
      reproducible: true,
      tier: nil,
      remat_in_flight: 0,
      remat_attempts: 0
    }

    %{g | nodes: Map.put(g.nodes, id, node)} |> set_step(step, :running, id)
  end

  defp bind_existing(g, step, id, node) do
    purged? = node.tier == :purged
    broken? = not node.reproducible

    status =
      case node.status do
        :complete when broken? -> :abandoned
        :complete when purged? -> :running
        :complete -> :done
        :failed -> :abandoned
        _pending_or_computing -> :running
      end

    g = set_step(g, step, status, id)

    if node.status == :complete and purged? and not broken? and node.remat_in_flight == 0 do
      put_node(g, id, %{node | remat_in_flight: 1, remat_attempts: 1})
    else
      g
    end
  end

  @doc "StepCompletesWithNode: a running step ends done when its node's result is available."
  @spec step_done(t(), key()) :: result()
  def step_done(g, step) do
    with {:ok, %{status: :running, node: n}} <- fetch_running(g, step),
         %{status: :complete, reproducible: true, tier: t} when t in [:hot, :cold] <- g.nodes[n] do
      {:ok, put_in(g.steps[step].status, :done)}
    else
      {:error, _} = e -> e
      _ -> {:error, :node_result_not_available}
    end
  end

  @doc "StepFailsWithNode: a running step is abandoned when its node failed or is irreproducible."
  @spec step_abandon(t(), key()) :: result()
  def step_abandon(g, step) do
    with {:ok, %{node: n}} <- fetch_running(g, step),
         %{status: st, reproducible: r} <- g.nodes[n],
         true <- (st == :failed or not r) || {:error, :node_not_failed} do
      {:ok, put_in(g.steps[step].status, :abandoned)}
    else
      {:error, _} = e -> e
      _ -> {:error, :node_not_failed}
    end
  end

  # Nodes ----------------------------------------------------------------------

  @doc "DispatchNode: a pending node with attempts left goes to a worker."
  @spec dispatch(t(), key()) :: result()
  def dispatch(g, n) do
    with {:ok, %{status: :pending, attempts: a} = node} <- fetch_node(g, n),
         true <- a < g.max_attempts || {:error, :attempts_exhausted} do
      {:ok, put_node(g, n, %{node | status: :computing, attempts: a + 1})}
    else
      {:ok, _} -> {:error, :node_not_pending}
      {:error, _} = e -> e
    end
  end

  @doc "ComputationSucceeds: the node completes with its result hash and a hot payload."
  @spec succeed(t(), key(), term()) :: result()
  def succeed(g, n, result_hash) when result_hash != nil do
    case fetch_node(g, n) do
      {:ok, %{status: :computing} = node} ->
        {:ok, put_node(g, n, %{node | status: :complete, result_hash: result_hash, tier: :hot})}

      {:ok, _} ->
        {:error, :node_not_computing}

      {:error, _} = e ->
        e
    end
  end

  @doc "ComputationCrashes / ComputationTimesOut: retry while attempts remain, then fail."
  @spec crash(t(), key()) :: result()
  def crash(g, n) do
    case fetch_node(g, n) do
      {:ok, %{status: :computing, attempts: a} = node} ->
        status = if a < g.max_attempts, do: :pending, else: :failed
        {:ok, put_node(g, n, %{node | status: status})}

      {:ok, _} ->
        {:error, :node_not_computing}

      {:error, _} = e ->
        e
    end
  end

  @doc "ComputationRejects: a deterministic rejection is terminal at once."
  @spec reject(t(), key()) :: result()
  def reject(g, n) do
    case fetch_node(g, n) do
      {:ok, %{status: :computing} = node} -> {:ok, put_node(g, n, %{node | status: :failed})}
      {:ok, _} -> {:error, :node_not_computing}
      {:error, _} = e -> e
    end
  end

  # Payload retention ------------------------------------------------------------

  @doc "PayloadMovesToColdStorage."
  @spec cool(t(), key()) :: result()
  def cool(g, n) do
    case fetch_node(g, n) do
      {:ok, %{status: :complete, tier: :hot} = node} ->
        {:ok, put_node(g, n, %{node | tier: :cold})}

      {:ok, _} ->
        {:error, :payload_not_hot}

      {:error, _} = e ->
        e
    end
  end

  @doc "PayloadPurged: never under a step still running on the node (D-063)."
  @spec purge(t(), key()) :: result()
  def purge(g, n) do
    with {:ok, %{status: :complete, tier: :cold} = node} <- fetch_node(g, n),
         false <- Enum.any?(g.steps, fn {_, s} -> s.status == :running and s.node == n end) do
      {:ok, put_node(g, n, %{node | tier: :purged})}
    else
      true -> {:error, :step_running_on_node}
      {:ok, _} -> {:error, :payload_not_cold}
      {:error, _} = e -> e
    end
  end

  @doc """
  RematerialisationSucceeds / MarkNodeIrreproducible: the answer of a recomputation.
  The same hash restores the payload; a different one marks the node irreproducible.
  An answer for a payload that is no longer purged is dropped.
  """
  @spec remat_answer(t(), key(), boolean()) :: result()
  def remat_answer(g, n, same?) when is_boolean(same?) do
    case fetch_node(g, n) do
      {:ok, %{remat_in_flight: f} = node} when f > 0 ->
        node = %{node | remat_in_flight: f - 1, remat_attempts: 0}

        node =
          cond do
            node.tier == :purged and same? -> %{node | tier: :hot}
            node.tier == :purged -> %{node | reproducible: false}
            true -> node
          end

        {:ok, put_node(g, n, node)}

      {:ok, _} ->
        {:error, :no_recomputation_in_flight}

      {:error, _} = e ->
        e
    end
  end

  @doc """
  RecomputationCrashes / RecomputationTimesOut (D-063): dispatched again while
  attempts remain; when they run out the cycle ends and the steps waiting for
  the payload are abandoned. The node stays reproducible.
  """
  @spec remat_crash(t(), key()) :: result()
  def remat_crash(g, n) do
    case fetch_node(g, n) do
      {:ok, %{remat_in_flight: f, tier: :purged, remat_attempts: a} = node} when f > 0 ->
        if a < g.max_attempts do
          {:ok, put_node(g, n, %{node | remat_attempts: a + 1})}
        else
          g = put_node(g, n, %{node | remat_in_flight: f - 1, remat_attempts: 0})
          {:ok, abandon_running_on(g, n)}
        end

      {:ok, _} ->
        {:error, :no_recomputation_to_lose}

      {:error, _} = e ->
        e
    end
  end

  @doc "RerunRequested (D-064): an inspector reruns a purged payload; a cycle with no step."
  @spec rerun(t(), key()) :: result()
  def rerun(g, n) do
    case fetch_node(g, n) do
      {:ok, %{status: :complete, tier: :purged, reproducible: true, remat_in_flight: 0} = node} ->
        {:ok, put_node(g, n, %{node | remat_in_flight: 1, remat_attempts: 1})}

      {:ok, _} ->
        {:error, :rerun_not_allowed}

      {:error, _} = e ->
        e
    end
  end

  # Helpers ----------------------------------------------------------------------

  defp abandon_running_on(g, n) do
    steps =
      Map.new(g.steps, fn
        {k, %{status: :running, node: ^n} = s} -> {k, %{s | status: :abandoned}}
        other -> other
      end)

    %{g | steps: steps}
  end

  defp request_status(g, req) do
    case g.requests do
      %{^req => %{status: st}} -> {:ok, st}
      _ -> {:error, :unknown_request}
    end
  end

  defp steps_of(g, req), do: for({_, s} <- g.steps, s.request == req, do: s)

  defp fetch_step(g, step) do
    case g.steps do
      %{^step => s} -> {:ok, s}
      _ -> {:error, :unknown_step}
    end
  end

  defp fetch_running(g, step) do
    case fetch_step(g, step) do
      {:ok, %{status: :running} = s} -> {:ok, s}
      {:ok, _} -> {:error, :step_not_running}
      {:error, _} = e -> e
    end
  end

  defp fetch_node(g, n) do
    case g.nodes do
      %{^n => node} -> {:ok, node}
      _ -> {:error, :unknown_node}
    end
  end

  defp set_step(g, step, status, node),
    do: %{g | steps: Map.update!(g.steps, step, &%{&1 | status: status, node: node})}

  defp put_node(g, n, node), do: %{g | nodes: Map.put(g.nodes, n, node)}
end
