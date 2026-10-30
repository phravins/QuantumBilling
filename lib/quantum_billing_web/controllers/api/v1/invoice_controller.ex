defmodule QuantumBillingWeb.API.V1.InvoiceController do
  @moduledoc """
  `/api/v1/invoices`: list, fetch and create.

  Reads and writes go through `QuantumBilling.Invoices` and nothing else, so
  the Bin, numbering and every side effect of issuing an invoice (the realtime
  update, the webhook, the notification) behave exactly as they do from the
  screens.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.{Audit, Clients, Invoices}
  alias QuantumBillingWeb.API.{Error, Idempotency, InvoiceParams, Pagination}
  alias QuantumBillingWeb.API.V1.InvoiceJSON
  alias QuantumBillingWeb.Plugs.RequireScope

  plug RequireScope, "invoices:read" when action in [:index, :show]
  plug RequireScope, "invoices:write" when action in [:create]

  def index(conn, params) do
    case Pagination.parse(params) do
      {:ok, page, per_page} ->
        result =
          [records: true, page: page, per_page: per_page]
          |> put_filter(:status, params["status"])
          |> put_filter(:search, params["search"])
          |> Invoices.page()
          |> Pagination.settle(page)

        json(conn, InvoiceJSON.index(%{page: result, api_key: conn.assigns.api_key}))

      {:error, fields} ->
        Error.send(conn, 400, :invalid_parameters, "The query parameters are invalid.", fields)
    end
  end

  def show(conn, %{"id" => id}) do
    case Invoices.get_invoice(id) do
      nil -> not_found(conn)
      invoice -> json(conn, InvoiceJSON.show(%{invoice: invoice, api_key: conn.assigns.api_key}))
    end
  end

  def create(conn, _params) do
    Idempotency.run(conn, fn -> create_invoice(conn) end)
  end

  defp create_invoice(conn) do
    key = conn.assigns.api_key

    with {:ok, client_id, attrs} <- InvoiceParams.cast(conn.body_params),
         {:client, %Clients.Client{} = client} <- {:client, Clients.get_client(client_id)},
         {:ok, invoice} <-
           attrs |> Map.merge(Invoices.client_snapshot(client)) |> Invoices.create_invoice() do
      Audit.log_event(:invoice_created, "Invoice", invoice.id,
        api_key_id: key.id,
        ip_address: conn.assigns.api_client_ip,
        details: %{"invoice_number" => invoice.invoice_number, "via" => "api"}
      )

      {201, InvoiceJSON.show(%{invoice: invoice, api_key: key})}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        validation_failed(Error.changeset_fields(changeset))

      {:error, fields} when is_map(fields) ->
        validation_failed(fields)

      {:client, nil} ->
        validation_failed(%{"client_id" => ["must be the id of an existing client"]})

      {:error, _reason} ->
        {500,
         %{error: %{code: "internal_error", message: "The invoice could not be created. Retry."}}}
    end
  end

  defp validation_failed(fields) do
    {422,
     %{error: %{code: "validation_failed", message: "The invoice is invalid.", fields: fields}}}
  end

  defp not_found(conn), do: Error.send(conn, 404, :not_found, "No such invoice.")

  defp put_filter(opts, _name, value) when value in [nil, ""], do: opts
  defp put_filter(opts, name, value) when is_binary(value), do: Keyword.put(opts, name, value)
  defp put_filter(opts, _name, _value), do: opts
end
