defmodule Veridian.Ledger do
  @moduledoc """
  The calculation ledger in PostgreSQL: `Veridian.Graph`'s rules applied to the
  `Veridian.Store` tables, one transaction per ledger step (D-056, D-061, D-072).

  Each function locks the rows it touches, loads them into a `Veridian.Graph`,
  calls the pure function, and writes the difference back, all in one
  transaction. The decision logic stays in `Veridian.Graph`, which the Quint
  model is replayed against; this module adds only storage and serialisation.

  ## Lock order (no cycles, so no deadlocks)

  request, then node, then step rows.

    * Request-level actions (`cancel/1`, `request_fulfil/1`, `request_fail/1`)
      take the request row exclusively.
    * Step actions (`bind/3`, `step_done/1`, `step_abandon/1`, `step_cancel/1`)
      take the request row *shared*, then the node, then only their own step
      row, and read its prerequisites unlocked (`done` is terminal). So the
      steps of one large request bind concurrently, and a cancel waits only for
      the binds already in flight.
    * Node-only actions take the node row; `remat_crash/1` then takes the steps
      running on it. `purge/1` only reads those steps, which is safe because
      binding a step to a node takes the node row first (D-063).

  Bundles (`bind_bundle/1`, `dispatch_bundle/1`, `complete_bundle/1`,
  `step_done_bundle/1`, ...) and the step actions take the same locks in the same
  order, but in a constant number of statements: each table is read and locked
  once (in key order), the pure graph is folded over every item in memory, and
  only the changed rows are written back, one statement per table (D-078).

  A memo hit through `bind/3` writes nothing to the node: it selects the node
  `FOR UPDATE` first, and only a miss inserts (in a savepoint, so a lost race
  does not abort the transaction).

  ## Keys

  Requests and steps are UUIDs. A node is a `Veridian.Id` of kind `:calc`; a
  result hash a `Veridian.Id` of kind `:result`.
  """

  alias Veridian.{Graph, Id, Repo}
  alias Veridian.Store.{Node, Request, Step}
  require Ash.Query

  @type result(t) :: {:ok, t} | {:error, term()}

  # Requests ---------------------------------------------------------------------

  @doc "AcceptCalculationRequest: opens a request with its planned steps (`%{step_id => [prerequisite_step_ids]}`)."
  @spec submit(Ecto.UUID.t(), %{Ecto.UUID.t() => [Ecto.UUID.t()]}) :: result(:ok)
  def submit(request_id, steps) do
    transact(fn ->
      existing_steps = Ash.read!(Step |> Ash.Query.filter(id in ^Map.keys(steps)))

      cond do
        request_exists?(request_id) ->
          Repo.rollback(:request_exists)

        existing_steps != [] ->
          Repo.rollback(:step_exists)

        true ->
          case Graph.submit(Graph.new(max_attempts()), request_id, steps) do
            {:ok, _} ->
              Ash.create!(Request, %{id: request_id})

              # One bulk insert in batches, not a statement per step.
              steps
              |> Enum.map(fn {id, prereqs} ->
                %{id: id, request_id: request_id, prerequisite_ids: prereqs}
              end)
              |> Ash.bulk_create!(Step, :create,
                batch_size: 1000,
                return_errors?: true,
                stop_on_error?: true
              )

              :ok

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
  end

  for {name, graph_fun} <- [
        request_fulfil: :request_fulfil,
        request_fail: :request_fail,
        cancel: :cancel
      ] do
    @doc "Applies `Veridian.Graph.#{graph_fun}/2` to a request, atomically."
    @spec unquote(name)(Ecto.UUID.t()) :: result(:ok)
    def unquote(name)(request_id) do
      transact(fn ->
        # Exclusive: waits for step actions in flight (they hold the request
        # FOR SHARE), so the steps read next cannot change under us, except by
        # remat_crash, whose effect is a valid ordering either way.
        req = lock_request!(request_id)
        steps = Ash.read!(Step |> Ash.Query.filter(request_id == ^request_id))
        slice = %{requests: [req], steps: steps, nodes: []}
        apply_graph(slice, &Graph.unquote(graph_fun)(&1, request_id))
      end)
    end
  end

  # Steps ------------------------------------------------------------------------

  @doc """
  StepBindsToNode. Creates the node when no node has this calc_id, otherwise
  meets the existing one. Returns `{:ok, :created | :existing}`.
  """
  @spec bind(Ecto.UUID.t(), Id.t(), DateTime.t()) :: result(:created | :existing)
  def bind(step_id, %Id{kind: :calc} = calc_id, %DateTime{} = as_of) do
    case bind_bundle([{step_id, calc_id, as_of}]) do
      {:ok, [kind]} -> {:ok, kind}
      {:error, _} = refusal -> refusal
    end
  end

  @doc """
  Binds a bundle of steps in one transaction (D-044): `[{step_id, calc_id,
  as_of}]`, returning the list of `:created | :existing` in the order given.
  All or nothing; nodes are taken in digest order so two bundles cannot deadlock.
  """
  @spec bind_bundle([{Ecto.UUID.t(), Id.t(), DateTime.t()}]) ::
          result([:created | :existing])
  def bind_bundle(items) do
    spec = %{
      steps: Enum.map(items, fn {step_id, _, _} -> step_id end),
      nodes: [],
      creates: Enum.map(items, fn {_, calc_id, as_of} -> {calc_id, as_of} end)
    }

    bundle(spec, fn g ->
      fold_all(g, items, fn g, {step_id, calc_id, _} -> Graph.bind(g, step_id, calc_id) end)
    end)
  end

  for {name, graph_fun} <- [
        step_done: :step_done,
        step_abandon: :step_abandon,
        step_cancel: :step_cancel
      ] do
    @doc "Applies `Veridian.Graph.#{graph_fun}/2` to a step, atomically."
    @spec unquote(name)(Ecto.UUID.t()) :: result(:ok)
    def unquote(name)(step_id), do: unit(unquote(:"#{name}_bundle")([step_id]))

    @doc """
    `#{name}/1` for a bundle of steps in one transaction (D-044), all or nothing,
    in a constant number of statements (D-078).
    """
    @spec unquote(:"#{name}_bundle")([Ecto.UUID.t()]) :: result(:ok)
    def unquote(:"#{name}_bundle")(step_ids) do
      bundle(%{steps: step_ids, nodes: [], creates: []}, fn g ->
        fold_all(g, step_ids, fn g, id -> Graph.unquote(graph_fun)(g, id) end)
      end)
      |> unit()
    end
  end

  defp unit({:ok, _}), do: {:ok, :ok}
  defp unit({:error, _} = e), do: e

  @doc "The result hash of the node a step is bound to, for building a dependent step's calc_id."
  @spec step_result_hash(Ecto.UUID.t()) :: result(Id.t())
  def step_result_hash(step_id) do
    with %Step{node_digest: d} when d != nil <- Ash.get!(Step, step_id),
         %Node{result_digest: r, result_scheme: s} when r != nil <- Ash.get!(Node, d) do
      Id.new(:result, String.to_existing_atom(s), r)
    else
      _ -> {:error, :no_result}
    end
  end

  # Nodes ------------------------------------------------------------------------

  for {name, graph_fun} <- [
        dispatch: :dispatch,
        crash: :crash,
        reject: :reject,
        cool: :cool,
        rerun: :rerun
      ] do
    @doc "Applies `Veridian.Graph.#{graph_fun}/2` to a node, atomically."
    @spec unquote(name)(Id.t()) :: result(:ok)
    def unquote(name)(%Id{kind: :calc} = calc_id) do
      transact(fn -> node_action(calc_id, &Graph.unquote(graph_fun)(&1, calc_id)) end)
    end
  end

  @doc """
  Dispatches a bundle of nodes in one transaction (D-044), all or nothing, in
  digest order.
  """
  @spec dispatch_bundle([Id.t()]) :: result(:ok)
  def dispatch_bundle(calc_ids) do
    bundle(%{steps: [], nodes: calc_ids, creates: []}, fn g ->
      fold_all(g, calc_ids, fn g, calc_id -> Graph.dispatch(g, calc_id) end)
    end)
    |> unit()
  end

  @doc "ComputationSucceeds for one node. Prefer `complete_bundle/1`, the real path (D-056)."
  @spec succeed(Id.t(), Id.t()) :: result(:ok)
  def succeed(%Id{kind: :calc} = calc_id, %Id{kind: :result} = result) do
    transact(fn -> node_action(calc_id, &Graph.succeed(&1, calc_id, result)) end)
  end

  @doc """
  PayloadPurged. Reads the steps running on the node without locking them: a
  binding step takes the node row first, so it cannot slip in between.
  """
  @spec purge(Id.t()) :: result(:ok)
  def purge(%Id{kind: :calc} = calc_id) do
    transact(fn ->
      node = lock_node!(calc_id)
      steps = Ash.read!(Step |> Ash.Query.filter(node_digest == ^calc_id.digest))
      apply_graph(%{requests: [], steps: steps, nodes: [node]}, &Graph.purge(&1, calc_id))
    end)
  end

  @doc """
  A lost recomputation (D-063): retried while attempts remain, then the steps
  waiting for the payload are abandoned. Takes the node row, then those steps.
  """
  @spec remat_crash(Id.t()) :: result(:ok)
  def remat_crash(%Id{kind: :calc} = calc_id) do
    transact(fn ->
      node = lock_node!(calc_id)
      steps = lock_steps_on_node(calc_id)
      apply_graph(%{requests: [], steps: steps, nodes: [node]}, &Graph.remat_crash(&1, calc_id))
    end)
  end

  @doc "RematerialisationSucceeds / MarkNodeIrreproducible: the answer of a recomputation."
  @spec remat_answer(Id.t(), boolean()) :: result(:ok)
  def remat_answer(%Id{kind: :calc} = calc_id, same?) when is_boolean(same?) do
    transact(fn -> node_action(calc_id, &Graph.remat_answer(&1, calc_id, same?)) end)
  end

  @doc """
  A bundle's completions in one transaction (D-056): every node completes, or
  none does. A node is complete only when this transaction commits. `pairs` is
  a list of `{calc_id, result_hash}`.
  """
  @spec complete_bundle([{Id.t(), Id.t()}]) :: result(:ok)
  def complete_bundle(pairs) do
    bundle(%{steps: [], nodes: Enum.map(pairs, &elem(&1, 0)), creates: []}, fn g ->
      fold_all(g, pairs, fn g, {calc_id, result} -> Graph.succeed(g, calc_id, result) end)
    end)
    |> unit()
  end

  # Bundle engine (D-078) -----------------------------------------------------------
  #
  # One transaction and a constant number of statements per bundle, whatever its
  # size: rows are read and locked once per table (requests shared, then nodes,
  # then steps: the lock order of the module doc, each table in key order, so
  # overlapping bundles cannot deadlock), the pure graph is folded over every item
  # in memory, and the changed rows are written back once per table. The decision
  # logic stays in `Veridian.Graph`; this part only moves rows.
  #
  # `spec`: `steps` are the step ids acted on, `nodes` the nodes acted on,
  # `creates` the `{calc_id, as_of}` a bind may have to create.

  defp bundle(spec, fold), do: bundle(spec, fold, 3)

  defp bundle(spec, fold, retries) do
    case transact(fn -> bundle_in_tx(spec, fold) end) do
      {:error, :stale_step} when retries > 0 -> bundle(spec, fold, retries - 1)
      other -> other
    end
  end

  defp bundle_in_tx(spec, fold) do
    steps0 = read_steps!(spec.steps)
    requests = lock_requests_shared!(steps0 |> Enum.map(& &1.request_id) |> Enum.uniq())

    created = create_missing_nodes!(spec.creates)

    wanted =
      Enum.map(spec.creates, fn {id, _} -> id.digest end) ++
        Enum.map(spec.nodes, & &1.digest) ++
        for(s <- steps0, s.node_digest != nil, do: s.node_digest)

    node_rows = lock_nodes!(Enum.uniq(wanted))
    by_digest = Map.new(node_rows, &{&1.calc_digest, &1})

    Enum.each(spec.nodes, fn id ->
      if not is_map_key(by_digest, id.digest), do: Repo.rollback(:unknown_node)
    end)

    # as_of is part of the calc_id: a caller whose as_of disagrees with the row
    # has a different calc_id in mind.
    Enum.each(spec.creates, fn {id, as_of} ->
      if DateTime.compare(by_digest[id.digest].as_of, as_of) != :eq,
        do: Repo.rollback(:as_of_mismatch)
    end)

    locked = lock_steps!(spec.steps)

    # The nodes were chosen from the unlocked read of the steps. A bind that
    # committed in between changed a step's node: start again.
    before = Map.new(steps0, &{&1.id, &1.node_digest})

    Enum.each(locked, fn s ->
      if s.node_digest != before[s.id], do: Repo.rollback(:stale_step)
    end)

    # Prerequisites are read without a lock: `done` is terminal, so a stale read
    # can only make the graph refuse a step that a moment later would be ready.
    own = MapSet.new(spec.steps)

    prereq_ids =
      locked
      |> Enum.flat_map(& &1.prerequisite_ids)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(own, &1))

    prereqs =
      if prereq_ids == [], do: [], else: Ash.read!(Step |> Ash.Query.filter(id in ^prereq_ids))

    # A node created here is not in the graph, so the graph creates it (the row
    # already holds the same defaults).
    {fresh, existing} = Enum.split_with(node_rows, &is_map_key(created, &1.calc_digest))
    slice = %{requests: requests, steps: locked ++ prereqs, nodes: existing, written: fresh}

    case run_graph(slice, fold) do
      {:ok, g2, value} ->
        write_back_bulk(slice, g2)
        value

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Folds an operation over the items in the given order. Stops at the first
  # refusal, which refuses the whole bundle. Returns the list of its answers.
  defp fold_all(graph, items, fun) do
    items
    |> Enum.reduce_while({:ok, graph, []}, fn item, {:ok, g, acc} ->
      case fun.(g, item) do
        {:ok, g2} -> {:cont, {:ok, g2, [:ok | acc]}}
        {:ok, g2, answer} -> {:cont, {:ok, g2, [answer | acc]}}
        {:error, _} = refusal -> {:halt, refusal}
      end
    end)
    |> case do
      {:ok, g, acc} -> {:ok, g, Enum.reverse(acc)}
      refusal -> refusal
    end
  end

  defp read_steps!([]), do: []

  defp read_steps!(ids) do
    ids = Enum.uniq(ids)
    rows = Ash.read!(Step |> Ash.Query.filter(id in ^ids))
    if length(rows) != length(ids), do: Repo.rollback(:unknown_step)
    rows
  end

  defp lock_requests_shared!([]), do: []

  defp lock_requests_shared!(ids) do
    rows =
      Request
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read!()

    if length(rows) != length(ids), do: Repo.rollback(:unknown_request)
    rows
  end

  defp lock_nodes!([]), do: []

  defp lock_nodes!(digests) do
    Node
    |> Ash.Query.filter(calc_digest in ^digests)
    |> Ash.Query.sort(calc_digest: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!()
  end

  defp lock_steps!([]), do: []

  defp lock_steps!(ids) do
    ids = Enum.uniq(ids)

    Step
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!()
  end

  # Every node a bind may need, in digest order, in one Ash bulk upsert with no
  # fields to update. An existing node is left unchanged (verified: its status
  # and counters stay), so a memo hit changes nothing; the rows inserted by this
  # transaction are told apart from those already there by the upsert metadata.
  defp create_missing_nodes!([]), do: %{}

  defp create_missing_nodes!(creates) do
    entries =
      creates
      |> Enum.uniq_by(fn {id, _} -> id.digest end)
      |> Enum.sort_by(fn {id, _} -> id.digest end)
      |> Enum.map(fn {id, as_of} ->
        %{calc_digest: id.digest, calc_scheme: scheme(id), as_of: as_of}
      end)

    case Ash.bulk_create(entries, Node, :create,
           upsert?: true,
           upsert_fields: [],
           return_records?: true,
           return_errors?: true,
           stop_on_error?: true,
           batch_size: 1000
         ) do
      %Ash.BulkResult{status: :success, records: rows} ->
        # The upsert returns every row, inserted or already there; its metadata
        # says which. Never guess: anything else refuses the bundle.
        (rows || [])
        |> Enum.flat_map(fn row ->
          case row.__metadata__[:upsert_action] do
            :insert -> [{row.calc_digest, true}]
            :update -> []
            unknown -> Repo.rollback({:unknown_upsert_action, unknown})
          end
        end)
        |> Map.new()

      other ->
        Repo.rollback({:ash_bulk_failed, other})
    end
  end

  # The changed rows only, in one Ash bulk upsert per resource (D-079). The rows
  # are all locked by this transaction, so the upsert only ever updates.
  defp write_back_bulk(slice, g2) do
    before = build_graph(slice)

    # The engine holds requests FOR SHARE, so that the steps of one request run
    # in parallel. No step operation changes a request (only fulfil, fail and
    # cancel do, and they lock it exclusively). If the graph ever did, writing it
    # here would upgrade a share lock, which two bundles of one request would
    # deadlock on: refuse instead of doing it silently.
    if Enum.any?(slice.requests, &(g2.requests[&1.id] != before.requests[&1.id])),
      do: Repo.rollback(:request_changed_under_share_lock)

    step_rows =
      for s <- slice.steps, g2.steps[s.id] != before.steps[s.id] do
        post = g2.steps[s.id]

        %{
          id: s.id,
          request_id: s.request_id,
          prerequisite_ids: s.prerequisite_ids,
          status: post.status,
          node_digest: post.node && post.node.digest,
          node_scheme: post.node && scheme(post.node)
        }
      end

    node_rows =
      for row <- slice.written ++ slice.nodes,
          post = g2.nodes[node_key(row)],
          post != to_gnode(row) do
        Map.merge(
          %{calc_digest: row.calc_digest, calc_scheme: row.calc_scheme, as_of: row.as_of},
          node_attrs(post)
        )
      end

    upsert!(Step, step_rows, [:status, :node_digest, :node_scheme])

    upsert!(Node, node_rows, [
      :status,
      :attempts,
      :result_digest,
      :result_scheme,
      :reproducible,
      :tier,
      :remat_in_flight,
      :remat_attempts
    ])
  end

  defp upsert!(_resource, [], _fields), do: :ok

  defp upsert!(resource, rows, fields) do
    case Ash.bulk_create(rows, resource, :create,
           upsert?: true,
           upsert_fields: fields,
           return_errors?: true,
           stop_on_error?: true,
           return_records?: false,
           batch_size: 1000
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      other -> Repo.rollback({:bulk_write_failed, other})
    end
  end

  # Reads ------------------------------------------------------------------------

  @doc "The whole ledger as a `Veridian.Graph`. For tests and inspection, not the hot path."
  @spec snapshot() :: Graph.t()
  def snapshot do
    reqs = Ash.read!(Request)
    steps = Ash.read!(Step)
    nodes = Ash.read!(Node)
    build_graph(%{requests: reqs, steps: steps, nodes: nodes})
  end

  @doc "Memo lookup: the node of a calc_id, as a map in `Veridian.Graph.gnode()` shape, or nil."
  @spec lookup(Id.t()) :: Graph.gnode() | nil
  def lookup(%Id{kind: :calc} = calc_id) do
    case Ash.get(Node, calc_id.digest) do
      {:ok, row} -> to_gnode(row)
      _ -> nil
    end
  end

  # Internals --------------------------------------------------------------------

  defp max_attempts, do: Application.get_env(:veridian, :max_attempts, 3)

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  # Most node actions read and change only the node row.
  defp node_action(calc_id, graph_fun) do
    apply_graph(%{requests: [], steps: [], nodes: [lock_node!(calc_id)]}, graph_fun)
  end

  defp apply_graph(slice, graph_fun) do
    case run_graph(slice, graph_fun) do
      {:ok, g2} ->
        write_back(slice, g2)
        :ok

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp run_graph(slice, graph_fun), do: graph_fun.(build_graph(slice))

  # Rows -> Graph ------------------------------------------------------------------

  defp build_graph(slice) do
    g = Graph.new(max_attempts())

    %{
      g
      | requests: Map.new(slice.requests, &{&1.id, %{status: &1.status}}),
        steps: Map.new(slice.steps, &{&1.id, to_gstep(&1)}),
        nodes: Map.new(slice.nodes, &{node_key(&1), to_gnode(&1)})
    }
  end

  defp to_gstep(%Step{} = s) do
    %{
      request: s.request_id,
      prerequisites: s.prerequisite_ids,
      status: s.status,
      node: s.node_digest && Id.new!(:calc, scheme_atom(s.node_scheme), s.node_digest)
    }
  end

  defp to_gnode(%Node{} = n) do
    %{
      status: n.status,
      attempts: n.attempts,
      result_hash:
        n.result_digest && Id.new!(:result, scheme_atom(n.result_scheme), n.result_digest),
      reproducible: n.reproducible,
      tier: n.tier,
      remat_in_flight: n.remat_in_flight,
      remat_attempts: n.remat_attempts
    }
  end

  defp node_key(%Node{} = n), do: Id.new!(:calc, scheme_atom(n.calc_scheme), n.calc_digest)

  # Graph -> rows: only what changed ---------------------------------------------------

  defp write_back(slice, g2) do
    before = build_graph(slice)

    for req <- slice.requests, g2.requests[req.id] != before.requests[req.id] do
      Ash.update!(req, %{status: g2.requests[req.id].status})
    end

    for step <- slice.steps, g2.steps[step.id] != before.steps[step.id] do
      after_step = g2.steps[step.id]
      node = after_step.node

      Ash.update!(step, %{
        status: after_step.status,
        node_digest: node && node.digest,
        node_scheme: node && scheme(node)
      })
    end

    for row <- Map.get(slice, :written, []) ++ slice.nodes do
      key = node_key(row)
      after_node = g2.nodes[key]
      current = to_gnode(row)

      if after_node != nil and after_node != current do
        Ash.update!(row, node_attrs(after_node))
      end
    end

    :ok
  end

  defp node_attrs(n) do
    %{
      status: n.status,
      attempts: n.attempts,
      result_digest: n.result_hash && n.result_hash.digest,
      result_scheme: n.result_hash && scheme(n.result_hash),
      reproducible: n.reproducible,
      tier: n.tier,
      remat_in_flight: n.remat_in_flight,
      remat_attempts: n.remat_attempts
    }
  end

  # Locked reads -------------------------------------------------------------------

  defp request_exists?(id),
    do: Ash.read_one!(Request |> Ash.Query.filter(id == ^id)) != nil

  defp lock_request!(id) do
    case Request
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.lock(:for_update)
         |> Ash.read_one!() do
      nil -> Repo.rollback(:unknown_request)
      req -> req
    end
  end

  defp lock_steps_on_node(%Id{digest: d}) do
    Step
    |> Ash.Query.filter(node_digest == ^d and status == :running)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!()
  end

  defp lock_node!(%Id{digest: d}) do
    case lock_node_by_digest(d) do
      nil -> Repo.rollback(:unknown_node)
      node -> node
    end
  end

  defp lock_node_by_digest(d) do
    Node |> Ash.Query.filter(calc_digest == ^d) |> Ash.Query.lock(:for_update) |> Ash.read_one!()
  end

  defp scheme(%Id{scheme: s}), do: Atom.to_string(s)

  defp scheme_atom(text) do
    Enum.find(Id.schemes(), &(Atom.to_string(&1) == text)) ||
      raise ArgumentError, "unknown hash scheme in ledger: #{inspect(text)}"
  end
end
