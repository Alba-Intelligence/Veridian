defmodule Veridian.InputsTest do
  @moduledoc """
  Bitemporal input versions (spec 01, D-082): recording, overlap refusal under
  concurrency, half-open periods, and point-in-time resolution by the times,
  including spec 01's own worked example (D-007).
  """
  use Veridian.DataCase, async: false

  alias Veridian.{Id, Inputs}
  alias Veridian.Store.{InputSeries, InputVersion}

  # Content ids come from the Julia canonical form (D-081): the frozen vectors.
  @vectors Path.expand(
             "../../../julia/VeridianCanonical/test/fixtures/content_v1_vectors.json",
             __DIR__
           )

  defp content(n) do
    %{"vectors" => vs} = @vectors |> File.read!() |> Jason.decode!()
    {:ok, id} = Id.parse("content/sha256_v1/" <> Enum.at(vs, n)["hash_hex"])
    id
  end

  defp t(day, h \\ 0), do: DateTime.new!(Date.new!(2011, 11, day), Time.new!(h, 0, 0, {0, 6}))

  setup do
    {:ok, _} = Inputs.register_series("usd-swap-curve", "schema/curve@1", :golden)
    :ok
  end

  test "a recorded version resolves with its typed content id" do
    {:ok, vid} = Inputs.record_version("usd-swap-curve", content(0), t(1))
    later = DateTime.add(DateTime.utc_now(), 1, :second)

    assert {:ok, %{version_id: ^vid, content: c}} = Inputs.resolve("usd-swap-curve", t(5), later)
    assert c == content(0)
    assert %Id{kind: :content, scheme: :sha256_v1} = c
  end

  test "a series key is registered once" do
    assert {:error, :series_exists} =
             Inputs.register_series("usd-swap-curve", "schema/curve@1", :golden)

    assert {:error, :unknown_data_class} = Inputs.register_series("x", "s", :nonsense)
  end

  test "periods are half-open: a version may start exactly where the previous ends" do
    {:ok, v1} = Inputs.record_version("usd-swap-curve", content(0), t(1), t(4))
    {:ok, v2} = Inputs.record_version("usd-swap-curve", content(1), t(4))
    later = DateTime.add(DateTime.utc_now(), 1, :second)

    assert {:ok, %{version_id: ^v2}} = Inputs.resolve("usd-swap-curve", t(4), later)

    just_before = DateTime.add(t(4), -1, :microsecond)
    assert {:ok, %{version_id: ^v1}} = Inputs.resolve("usd-swap-curve", just_before, later)
  end

  test "an overlapping or empty period is refused" do
    {:ok, _} = Inputs.record_version("usd-swap-curve", content(0), t(1), t(4))
    assert {:error, :overlap} = Inputs.record_version("usd-swap-curve", content(1), t(3))
    assert {:error, :overlap} = Inputs.record_version("usd-swap-curve", content(1), t(2), t(3))
    assert {:error, :bad_range} = Inputs.record_version("usd-swap-curve", content(1), t(9), t(9))
    assert {:error, :unknown_series} = Inputs.record_version("nope", content(1), t(9))
  end

  test "resolution never sees what was recorded after the knowledge time" do
    before_recording = DateTime.add(DateTime.utc_now(), -1, :second)
    {:ok, _} = Inputs.record_version("usd-swap-curve", content(0), t(1))
    assert {:error, :unresolvable} = Inputs.resolve("usd-swap-curve", t(5), before_recording)
    assert {:error, :unresolvable} = Inputs.resolve("unknown-series", t(5), DateTime.utc_now())
  end

  test "concurrent overlapping records for one series: exactly one succeeds" do
    outcomes =
      1..20
      |> Task.async_stream(
        fn i ->
          Inputs.record_version("usd-swap-curve", content(rem(i, 40)), t(1, rem(i, 20)))
        end,
        max_concurrency: 10,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, o} -> o end)

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert Enum.count(outcomes, &(&1 == {:error, :overlap})) == 19
  end

  # Spec 01's worked example (golden USD swap curve, D-007), with the rows as
  # supersession would leave them (supersession itself is not built yet):
  #   v1 recorded 11-01, effective [11-01, open), content A, superseded 11-03;
  #   r1 remainder recorded 11-03, effective [11-01, 11-04), content A;
  #   c  correction recorded 11-03, effective [11-04, open), content B.
  test "spec 01 worked example: resolution by effective and knowledge time" do
    %InputSeries{id: sid} = Ash.read_one!(InputSeries)
    a = content(0)
    b = content(1)

    row = fn attrs ->
      Ash.create!(
        InputVersion,
        Map.merge(
          %{
            series_id: sid,
            content_scheme: "sha256_v1",
            submitted_at: t(1),
            effective_to: nil,
            superseded_at: nil
          },
          attrs
        )
      )
    end

    v1 =
      row.(%{
        content_digest: a.digest,
        effective_from: t(1),
        recorded_at: t(1),
        superseded_at: t(3),
        origin: :original,
        status: :superseded
      })

    r1 =
      row.(%{
        content_digest: a.digest,
        effective_from: t(1),
        effective_to: t(4),
        recorded_at: t(3),
        origin: :remainder,
        status: :active
      })

    c =
      row.(%{
        content_digest: b.digest,
        effective_from: t(4),
        recorded_at: t(3),
        origin: :correction,
        status: :active
      })

    assert {:ok, %{version_id: id1, content: ^a}} = Inputs.resolve("usd-swap-curve", t(5), t(2))
    assert id1 == v1.id
    assert {:ok, %{version_id: id2, content: ^a}} = Inputs.resolve("usd-swap-curve", t(2), t(13))
    assert id2 == r1.id
    assert {:ok, %{version_id: id3, content: ^b}} = Inputs.resolve("usd-swap-curve", t(5), t(13))
    assert id3 == c.id
  end

  test "data that breaks the no-overlap rule resolves to an error, never to the first match" do
    %InputSeries{id: sid} = Ash.read_one!(InputSeries)

    for n <- [0, 1] do
      Ash.create!(InputVersion, %{
        series_id: sid,
        content_digest: content(n).digest,
        content_scheme: "sha256_v1",
        effective_from: t(1),
        submitted_at: t(1),
        recorded_at: t(1),
        origin: :original,
        status: :active
      })
    end

    assert {:error, {:ambiguous, 2}} = Inputs.resolve("usd-swap-curve", t(2), t(5))
  end
end
