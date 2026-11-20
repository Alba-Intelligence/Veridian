defmodule Veridian.CalcIdTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Veridian.{CalcId, Id}

  @vectors "fixtures/calc_id_v1_vectors.json"
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("vectors")

  defp id!(text), do: text |> Id.parse() |> elem(1)

  defp args(v) do
    {:ok, as_of, 0} = DateTime.from_iso8601(v["as_of"])

    %{
      model_code: id!(v["model_code"]),
      as_of: as_of,
      inputs: Enum.map(v["inputs"], &id!/1),
      prerequisites: Enum.map(v["prerequisites"], &id!/1)
    }
  end

  describe "frozen scheme sha256_v1 vectors (written by an independent Python generator)" do
    for v <- @vectors do
      @v v
      test "#{v["name"]}" do
        a = args(@v)
        micros = DateTime.to_unix(a.as_of, :microsecond)

        assert Base.encode16(
                 CalcId.preimage(a.model_code, micros, a.inputs, a.prerequisites),
                 case: :lower
               ) == @v["preimage_hex"]

        assert {:ok, id} = CalcId.compute(a)
        assert Id.to_string(id) == @v["calc_id"]
      end
    end

    test "input order does not matter, duplicates do" do
      by_name = Map.new(@vectors, &{&1["name"], &1["calc_id"]})
      assert by_name["inputs_in_given_order_a_b_c"] == by_name["inputs_in_other_order_c_a_b"]
      refute by_name["duplicate_input_is_kept"] == by_name["one_input"]
    end
  end

  # Generators ---------------------------------------------------------------

  defp digest, do: binary(length: 32)
  defp id(kind), do: map(digest(), &Id.new!(kind, :sha256_v1, &1))

  defp as_of do
    map(integer(-4_000_000_000_000_000..4_000_000_000_000_000), fn us ->
      DateTime.from_unix!(us, :microsecond)
    end)
  end

  defp args_gen do
    fixed_map(%{
      model_code: id(:model_code),
      as_of: as_of(),
      inputs: list_of(id(:content), max_length: 6),
      prerequisites: list_of(id(:result), max_length: 6)
    })
  end

  describe "properties" do
    property "the calc_id is a calc identifier under the same scheme" do
      check all(a <- args_gen()) do
        assert {:ok, %Id{kind: :calc, scheme: :sha256_v1, digest: d}} = CalcId.compute(a)
        assert byte_size(d) == 32
      end
    end

    property "inputs and prerequisites in any order give the same calc_id" do
      check all(a <- args_gen(), seed <- integer()) do
        shuffled = %{
          a
          | inputs: shuffle(a.inputs, seed),
            prerequisites: shuffle(a.prerequisites, seed + 1)
        }

        assert CalcId.compute(a) == CalcId.compute(shuffled)
      end
    end

    property "different arguments never share a preimage (injective encoding)" do
      check all(a <- args_gen(), b <- args_gen()) do
        pa = pre(a)
        pb = pre(b)
        same_args = canon(a) == canon(b)
        assert same_args == (pa == pb)
      end
    end

    property "dropping or adding one input changes the calc_id" do
      check all(a <- args_gen(), extra <- id(:content)) do
        {:ok, base} = CalcId.compute(a)
        {:ok, more} = CalcId.compute(%{a | inputs: [extra | a.inputs]})
        refute base == more
      end
    end

    property "an input and a prerequisite with the same digest are not interchangeable" do
      check all(d <- digest(), m <- id(:model_code), as_of <- as_of()) do
        as_input = %{
          model_code: m,
          as_of: as_of,
          inputs: [Id.new!(:content, :sha256_v1, d)],
          prerequisites: []
        }

        as_prereq = %{
          model_code: m,
          as_of: as_of,
          inputs: [],
          prerequisites: [Id.new!(:result, :sha256_v1, d)]
        }

        refute CalcId.compute(as_input) == CalcId.compute(as_prereq)
      end
    end
  end

  describe "validation" do
    setup do
      {:ok, a: args(hd(@vectors))}
    end

    test "rejects a non-UTC as_of", %{a: a} do
      {:ok, dt} = DateTime.new(~D[2026-11-20], ~T[00:00:00], "Etc/UTC")
      shifted = %{dt | time_zone: "Asia/Hong_Kong", zone_abbr: "HKT", utc_offset: 28_800}
      assert {:error, {:as_of, :must_be_utc_datetime}} = CalcId.compute(%{a | as_of: shifted})
    end

    test "rejects an identifier of the wrong kind", %{a: a} do
      wrong = Id.new!(:result, :sha256_v1, :binary.copy(<<1>>, 32))
      assert {:error, {:inputs, :wrong_kind}} = CalcId.compute(%{a | inputs: [wrong]})

      assert {:error, {:model_code, :wrong_kind}} =
               CalcId.compute(%{a | model_code: wrong})

      content = Id.new!(:content, :sha256_v1, :binary.copy(<<1>>, 32))

      assert {:error, {:prerequisites, :wrong_kind}} =
               CalcId.compute(%{a | prerequisites: [content]})
    end

    test "rejects missing arguments" do
      assert {:error, :missing_arguments} = CalcId.compute(%{})
    end
  end

  describe "Veridian.Id" do
    test "text form round-trips and is strict" do
      id = Id.new!(:content, :sha256_v1, :binary.copy(<<171>>, 32))
      assert {:ok, ^id} = id |> Id.to_string() |> Id.parse()
      assert {:error, _} = Id.parse(String.upcase(Id.to_string(id)))
      assert {:error, _} = Id.parse("content/sha256_v1/abcd")

      assert {:error, {:unknown_scheme, "md5"}} =
               Id.parse("content/md5/" <> String.duplicate("0", 64))

      assert {:error, {:unknown_kind, "node"}} =
               Id.parse("node/sha256_v1/" <> String.duplicate("0", 64))

      assert {:error, :malformed} = Id.parse("nonsense")
    end

    test "new/3 rejects a wrong-sized digest, kind or scheme" do
      assert {:error, {:bad_digest, _}} = Id.new(:calc, :sha256_v1, <<1, 2>>)

      assert {:error, {:unknown_kind, :other}} =
               Id.new(:other, :sha256_v1, :binary.copy(<<0>>, 32))

      assert {:error, {:unknown_scheme, :md5}} = Id.new(:calc, :md5, :binary.copy(<<0>>, 32))
    end
  end

  # Helpers -------------------------------------------------------------------

  defp pre(a),
    do:
      CalcId.preimage(
        a.model_code,
        DateTime.to_unix(a.as_of, :microsecond),
        a.inputs,
        a.prerequisites
      )

  defp canon(a) do
    {a.model_code, DateTime.to_unix(a.as_of, :microsecond),
     Enum.sort_by(a.inputs, &Id.sort_key/1), Enum.sort_by(a.prerequisites, &Id.sort_key/1)}
  end

  defp shuffle(list, seed) do
    :rand.seed(:exsss, {seed, seed, seed})
    Enum.shuffle(list)
  end
end
