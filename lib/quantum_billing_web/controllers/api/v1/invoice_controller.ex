defmodule QuantumBillingWeb.API.V1.InvoiceController do
  @moduledoc """
  `/api/v1/invoices`: list, fetch and create.

  Reads and writes go through `QuantumBilling.Invoices` and nothing else, so
  the Bin, numbering and every side effect of issuing an invoice (the realtime
  update, the webhook, the notification) behave exactly as they do from the
  screens.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.{Audit, Clients, Invoices, Payments}
  alias QuantumBillingWeb.API.{ActionParams, Error, Idempotency, InvoiceParams, Pagination}
  alias QuantumBillingWeb.API.V1.InvoiceJSON
  alias QuantumBillingWeb.Plugs.RequireScope

  plug RequireScope, "invoices:read" when action in [:index, :show]
  plug RequireScope, "invoices:write" when action in [:create, :cancel]
  plug RequireScope, "invoices:payments" when action in [:record_payment]
  plug RequireScope, "invoices:e_invoice" when action in [:register_e_invoice]

  def index(conn, params) do
    case Pagination.parse(params) do
      {:ok, page, per_page} ->
        result =
          [records: true]
          |> put_filter(:status, params["status"])
          |> put_filter(:search, params["search"])
          |> then(&Pagination.context_opts(page, per_page, &1))
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

  @doc """
  `POST /invoices/:id/payments`: a payment received outside the gateway. The
  amount must cover the invoice; see `QuantumBilling.Payments.record_payment/4`.
  """
  def record_payment(conn, %{"id" => id}) do
    Idempotency.run(conn, fn ->
      with {:invoice, %{} = invoice} <- {:invoice, Invoices.get_invoice(id)},
           {:ok, reference, amount} <- ActionParams.payment(conn.body_params),
           {:ok, paid} <- Payments.record_payment(invoice, reference, amount, audit_opts(conn)) do
        {200,
         InvoiceJSON.show(%{invoice: Invoices.get_invoice(paid.id), api_key: conn.assigns.api_key})}
      else
        {:invoice, nil} ->
          not_found_body()

        {:error, :already_paid} ->
          conflict(:already_paid, "This invoice is already paid.")

        {:error, :cancelled} ->
          conflict(:cancelled, "A cancelled invoice cannot be paid.")

        {:error, :partial_payment} ->
          validation_failed(%{
            "amount" => [
              "must cover the invoice's grand total; partial payments are not supported"
            ]
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          validation_failed(Error.changeset_fields(changeset))

        {:error, fields} when is_map(fields) ->
          validation_failed(fields)
      end
    end)
  end

  @doc """
  `POST /invoices/:id/cancel`. Refused for a paid invoice, a live IRN or a live
  e-way bill; see `QuantumBilling.Invoices.cancel_invoice/3`.
  """
  def cancel(conn, %{"id" => id}) do
    Idempotency.run(conn, fn ->
      with {:invoice, %{} = invoice} <- {:invoice, Invoices.get_invoice(id)},
           {:ok, reason} <- ActionParams.cancellation(conn.body_params),
           {:ok, cancelled} <- Invoices.cancel_invoice(invoice, reason, audit_opts(conn)) do
        {200,
         InvoiceJSON.show(%{
           invoice: Invoices.get_invoice(cancelled.id),
           api_key: conn.assigns.api_key
         })}
      else
        {:invoice, nil} ->
          not_found_body()

        {:error, :already_cancelled} ->
          conflict(:already_cancelled, "This invoice is already cancelled.")

        {:error, :paid} ->
          conflict(:paid, "A paid invoice cannot be cancelled; raise a credit note instead.")

        {:error, :irn_registered} ->
          conflict(:irn_registered, "This invoice has a live IRN. Cancel it on the IRP first.")

        {:error, :live_e_way_bill} ->
          conflict(:live_e_way_bill, "This invoice has a live e-way bill. Cancel that first.")

        {:error, fields} when is_map(fields) ->
          validation_failed(fields)
      end
    end)
  end

  @doc """
  `POST /invoices/:id/e-invoice`: queues registration with the IRP. Answers
  202 while queued; the result arrives as `invoice.e_invoice_generated` or
  `invoice.e_invoice_failed`, or by fetching the invoice.
  """
  def register_e_invoice(conn, %{"id" => id}) do
    Idempotency.run(conn, fn ->
      with {:invoice, %{} = invoice} <- {:invoice, Invoices.get_invoice(id)},
           :ok <- ActionParams.empty(conn.body_params),
           :ok <- registrable(invoice),
           {:ok, outcome} <- Invoices.queue_einvoice(invoice) do
        Audit.log_event(:e_invoice_requested, "Invoice", invoice.id, audit_opts(conn))
        status = if outcome == :queued, do: 202, else: 200
        {status, %{data: %{status: to_string(outcome), invoice_id: invoice.id}}}
      else
        {:invoice, nil} ->
          not_found_body()

        {:conflict, code, message} ->
          conflict(code, message)

        {:error, fields} when is_map(fields) ->
          validation_failed(fields)

        {:error, _reason} ->
          {500,
           %{
             error: %{code: "internal_error", message: "Could not queue the registration. Retry."}
           }}
      end
    end)
  end

  # The invoice's one status field carries both payment and e-invoice state:
  # queueing stamps "Pending E-Invoice" and the outcome stamps again, so a
  # cancelled invoice would be quietly un-cancelled and a paid one would stop
  # saying Paid. Refused rather than allowed to lose that.
  defp registrable(%{status: "Cancelled"}),
    do: {:conflict, :cancelled, "A cancelled invoice cannot be registered with the IRP."}

  defp registrable(%{status: "Paid"}),
    do:
      {:conflict, :paid,
       "This invoice is already paid; registering it here would overwrite that status."}

  defp registrable(_invoice), do: :ok

  defp audit_opts(conn),
    do: [api_key_id: conn.assigns.api_key.id, ip_address: conn.assigns.api_client_ip]

  defp conflict(code, message), do: {409, %{error: %{code: to_string(code), message: message}}}

  defp not_found_body, do: {404, %{error: %{code: "not_found", message: "No such invoice."}}}

  defp validation_failed(fields) do
    {422,
     %{error: %{code: "validation_failed", message: "The invoice is invalid.", fields: fields}}}
  end

  defp not_found(conn), do: Error.send(conn, 404, :not_found, "No such invoice.")

  defp put_filter(opts, _name, value) when value in [nil, ""], do: opts
  defp put_filter(opts, name, value) when is_binary(value), do: Keyword.put(opts, name, value)
  defp put_filter(opts, _name, _value), do: opts
end
