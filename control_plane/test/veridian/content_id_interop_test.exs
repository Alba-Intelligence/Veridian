defmodule Veridian.ContentIdInteropTest do
  @moduledoc """
  The control plane accepts the content hashes the Julia canonical form writes
  (D-081): `content/sha256_v1/<hex>` parses to a `:content` identifier. The
  control plane never computes a content hash itself; these come from the
  package's frozen content vectors.
  """
  use ExUnit.Case, async: true

  alias Veridian.Id

  @vectors Path.expand(
             "../../../julia/VeridianCanonical/test/fixtures/content_v1_vectors.json",
             __DIR__
           )

  test "every frozen Julia content hash is a valid sha256_v1 content identifier" do
    %{"scheme" => scheme, "domain" => domain, "vectors" => vectors} =
      @vectors |> File.read!() |> Jason.decode!()

    assert scheme == "sha256_v1"
    assert domain == "veridian/content/sha256_v1"
    assert vectors != []

    for %{"hash_hex" => hex} <- vectors do
      assert {:ok, %Id{kind: :content, scheme: :sha256_v1} = id} =
               Id.parse("content/#{scheme}/#{hex}")

      assert Id.to_string(id) == "content/sha256_v1/#{hex}"
    end
  end
end
