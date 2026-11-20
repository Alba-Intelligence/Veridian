defmodule Veridian.ResultIdInteropTest do
  @moduledoc """
  The control plane accepts the result hashes the Julia package
  `VeridianCanonical` writes (D-075): the text form `result/sha256_v1/<hex>`
  parses to a `:result` identifier, and its digest feeds `Veridian.CalcId`
  as a prerequisite. The hashes come from the package's frozen vectors.
  """
  use ExUnit.Case, async: true

  alias Veridian.Id

  @vectors Path.expand(
             "../../../julia/VeridianCanonical/test/fixtures/canonical_v1_vectors.json",
             __DIR__
           )

  test "every frozen Julia result hash is a valid sha256_v1 result identifier" do
    %{"scheme" => scheme, "vectors" => vectors} = @vectors |> File.read!() |> Jason.decode!()
    assert scheme == "sha256_v1"
    assert vectors != []

    for %{"hash_hex" => hex} <- vectors do
      assert {:ok, %Id{kind: :result, scheme: :sha256_v1, digest: digest} = id} =
               Id.parse("result/#{scheme}/#{hex}")

      assert Base.encode16(digest, case: :lower) == hex
      assert Id.to_string(id) == "result/sha256_v1/#{hex}"
    end
  end
end
