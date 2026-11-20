defmodule Veridian.StoreTest do
  use Veridian.DataCase, async: false

  alias Veridian.Store.{Node, Request, Step}

  @digest :binary.copy(<<7>>, 32)

  defp node_attrs(extra \\ %{}) do
    Map.merge(
      %{
        calc_digest: @digest,
        calc_scheme: "sha256_v1",
        as_of: ~U[2026-11-20 00:00:00.000001Z]
      },
      extra
    )
  end

  test "a node round-trips through Ash with its defaults" do
    node = Ash.create!(Node, node_attrs())
    assert node.status == :pending and node.attempts == 0 and node.reproducible

    [read] = Ash.read!(Node)
    assert read.calc_digest == @digest
    assert read.as_of == ~U[2026-11-20 00:00:00.000001Z]
    assert read.tier == nil
  end

  test "a request, a step and its node binding round-trip" do
    req = Ash.create!(Request, %{})
    assert req.status == :open
    step = Ash.create!(Step, %{request_id: req.id})
    assert step.status == :waiting and step.prerequisite_ids == []
    bound = Ash.update!(step, %{status: :running, node_digest: @digest, node_scheme: "sha256_v1"})
    assert bound.node_digest == @digest
  end

  test "the database refuses a digest of the wrong size" do
    assert {:error, _} = Ash.create(Node, node_attrs(%{calc_digest: <<1, 2, 3>>}))
  end

  test "the database refuses a complete node without a result, and a result without completion" do
    assert {:error, _} = Ash.create(Node, node_attrs(%{status: :complete}))

    assert {:error, _} =
             Ash.create(Node, node_attrs(%{result_digest: @digest, result_scheme: "sha256_v1"}))

    assert {:ok, _} =
             Ash.create(
               Node,
               node_attrs(%{
                 status: :complete,
                 result_digest: @digest,
                 result_scheme: "sha256_v1",
                 tier: :hot
               })
             )
  end

  test "one node per calc_id" do
    Ash.create!(Node, node_attrs())
    assert {:error, _} = Ash.create(Node, node_attrs())
  end
end
