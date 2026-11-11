defmodule QuantumBilling.DocsVersionTest do
  @moduledoc """
  The README, the docs index and the deployment guide state the release
  version. They have to move with `version` in mix.exs, or the first thing a
  reader sees is wrong.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp version, do: Mix.Project.config()[:version]

  defp read(path), do: File.read!(Path.join(@root, path))

  # Every `v<major>.<minor>.<patch>` in these files is the release version;
  # other versions (OpenAPI, dependencies) are written without the `v`.
  for path <- ["README.md", "docs/README.md"] do
    test "#{path} states the release version and no other" do
      stated = Regex.scan(~r/\bv(\d+\.\d+\.\d+)\b/, read(unquote(path)), capture: :all_but_first)

      assert stated != [], "#{unquote(path)} does not state a version"
      assert Enum.uniq(List.flatten(stated)) == [version()]
    end
  end

  test "the deployment guide's release paths use the release version" do
    paths = Regex.scan(~r/quantum_billing-(\d+\.\d+\.\d+)/, read("docs/deployment.md"))

    assert paths != []
    assert paths |> Enum.map(&List.last/1) |> Enum.uniq() == [version()]
  end
end
