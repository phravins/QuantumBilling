defmodule QuantumBillingWeb.API.OpenAPITest do
  @moduledoc """
  `docs/openapi.json` describes the API that exists — no more, no less.

  It is written by hand, so these tests are what keep it true: a route added
  without a spec entry, a serializer field added without a schema property, or
  a scope renamed in one place only, fails here.
  """
  use ExUnit.Case, async: true

  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBillingWeb.API.V1

  @spec_path Path.expand("../../../docs/openapi.json", __DIR__)

  setup_all do
    %{spec: @spec_path |> File.read!() |> Jason.decode!()}
  end

  defp properties(spec, schema), do: spec["components"]["schemas"][schema]["properties"]

  test "every API route is in the spec, and the spec has no route the API lacks", %{spec: spec} do
    routes =
      QuantumBillingWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1/"))
      |> Enum.reject(&(&1.path == "/api/v1/*path"))
      |> Enum.map(fn route ->
        path =
          route.path
          |> String.replace_prefix("/api/v1", "")
          |> String.replace(~r{:(\w+)}, "{\\1}")

        {to_string(route.verb), path}
      end)
      |> Enum.sort()

    documented =
      for {path, operations} <- spec["paths"], {verb, _op} <- operations do
        {verb, path}
      end
      |> Enum.sort()

    assert documented == routes
  end

  test "each schema's properties are exactly its serializer's fields", %{spec: spec} do
    for {schema, fields, optional} <- [
          {"Invoice", V1.InvoiceJSON.fields(), ~w(items payment_url)},
          {"Client", V1.ClientJSON.fields(), []},
          {"EWayBill", V1.EWayBillJSON.fields(), []},
          {"CreditNote", V1.CreditNoteJSON.fields(), []}
        ] do
      documented = spec |> properties(schema) |> Map.keys() |> Enum.sort()
      actual = (Enum.map(fields, &to_string/1) ++ optional) |> Enum.sort()

      assert documented == actual, "#{schema} in the spec has drifted from its serializer"
    end
  end

  test "an invoice line documents exactly the serializer's item fields", %{spec: spec} do
    documented =
      spec |> properties("Invoice") |> get_in(["items", "items", "properties"]) |> Map.keys()

    assert Enum.sort(documented) ==
             V1.InvoiceJSON.item_fields() |> Enum.map(&to_string/1) |> Enum.sort()
  end

  test "every operation names a scope that exists, and only /me needs none", %{spec: spec} do
    for {path, operations} <- spec["paths"], {verb, op} <- operations do
      case op["x-required-scope"] do
        nil -> assert path == "/me", "#{verb} #{path} documents no scope"
        scope -> assert scope in ApiKey.scopes(), "#{verb} #{path}: unknown scope #{scope}"
      end
    end
  end

  test "every write documents the Idempotency-Key header", %{spec: spec} do
    for {path, operations} <- spec["paths"], {"post", op} <- operations do
      names = Enum.map(op["parameters"] || [], & &1["name"])
      assert "Idempotency-Key" in names, "POST #{path} omits Idempotency-Key"
    end
  end
end
