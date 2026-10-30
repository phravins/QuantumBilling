defmodule QuantumBillingWeb.API.V1.EWayBillController do
  @moduledoc "`/api/v1/e-way-bills`: read-only, through `QuantumBilling.EWayBills`."
  use QuantumBillingWeb, :controller

  alias QuantumBilling.EWayBills
  alias QuantumBillingWeb.API.{Error, Pagination}
  alias QuantumBillingWeb.API.V1.EWayBillJSON
  alias QuantumBillingWeb.Plugs.RequireScope

  plug RequireScope, "e_way_bills:read"

  def index(conn, params) do
    case Pagination.parse(params) do
      {:ok, page, per_page} ->
        opts =
          [records: true]
          |> put_filter(:status, params["status"])
          |> put_filter(:search, params["search"])
          |> then(&Pagination.context_opts(page, per_page, &1))

        json(
          conn,
          EWayBillJSON.index(%{page: opts |> EWayBills.page() |> Pagination.settle(page)})
        )

      {:error, fields} ->
        Error.send(conn, 400, :invalid_parameters, "The query parameters are invalid.", fields)
    end
  end

  # `get_listed_e_way_bill/1`, not `get_e_way_bill/1`: a bill whose invoice is
  # in the Bin is hidden from the list, so it must not be fetchable by id either.
  def show(conn, %{"id" => id}) do
    case EWayBills.get_listed_e_way_bill(id) do
      nil -> Error.send(conn, 404, :not_found, "No such e-way bill.")
      bill -> json(conn, EWayBillJSON.show(%{bill: bill}))
    end
  end

  defp put_filter(opts, _name, value) when value in [nil, ""], do: opts
  defp put_filter(opts, name, value) when is_binary(value), do: Keyword.put(opts, name, value)
  defp put_filter(opts, _name, _value), do: opts
end
