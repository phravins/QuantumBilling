defmodule QuantumBilling.ComposeFilesTest do
  # docker-compose.yml (plain host) and docker-compose.coolify.yml (PaaS) are
  # written out separately; these checks keep them from drifting apart.
  use ExUnit.Case, async: true

  @plain File.read!(Path.expand("../../docker-compose.yml", __DIR__))
  @coolify File.read!(Path.expand("../../docker-compose.coolify.yml", __DIR__))

  defp env_keys(compose) do
    ~r/^\s+([A-Z][A-Z0-9_]*):/m
    |> Regex.scan(compose, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "both files pass the same settings to the app and the database" do
    assert "PHX_HOST" in env_keys(@plain)
    assert env_keys(@coolify) == env_keys(@plain)
  end

  test "PHX_HOST is required in both files" do
    assert @plain =~ "PHX_HOST: ${PHX_HOST:?"
    assert @coolify =~ "PHX_HOST: ${PHX_HOST:?}\n"
  end

  test "required Coolify variables carry no text after the question mark" do
    # Coolify reads ${VAR:?text} as a prefilled value, not an error message.
    refute @coolify =~ ~r/\$\{[A-Za-z0-9_]+:?\?[^}]/
  end

  test "the Coolify file builds once and leaves routing to the platform proxy" do
    assert length(Regex.scan(~r/^\s+build:/m, @coolify)) == 1
    refute @coolify =~ ~r/^\s+image: quantum_billing/m
    refute @coolify =~ ~r/^\s+ports:/m
    refute @coolify =~ ~r/^\s+migrate:/m
    assert @coolify =~ ~s(command: ["sh", "-c", "bin/migrate && exec bin/server"])
  end
end
