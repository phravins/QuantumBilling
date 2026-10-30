defmodule QuantumBillingWeb.API.V1.CreditNoteController do
  @moduledoc """
  `/api/v1/credit-notes` (read) and `POST /api/v1/invoices/:id/credit-notes`,
  through `QuantumBilling.CreditNotes`. Lists are cursor-paged only: notes have
  no screen with numbered pages to mirror.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.{Audit, CreditNotes, Invoices}
  alias QuantumBillingWeb.API.{ActionParams, Error, Idempotency, Pagination}
  alias QuantumBillingWeb.API.V1.CreditNoteJSON
  alias QuantumBillingWeb.Plugs.RequireScope

  plug RequireScope, "credit_notes:read" when action in [:index, :show]
  plug RequireScope, "credit_notes:write" when action in [:create]

  def index(conn, params) do
    params = Map.put_new(params, "paginate", "cursor")

    case Pagination.parse(params) do
      {:ok, {:cursor, before_id}, per_page} ->
        result = CreditNotes.page(before_id: before_id, per_page: per_page)
        json(conn, CreditNoteJSON.index(%{page: result}))

      {:ok, _page, _per_page} ->
        Error.send(conn, 400, :invalid_parameters, "Credit notes are cursor-paged.", %{
          "page" => ["is not supported here; use cursor"]
        })

      {:error, fields} ->
        Error.send(conn, 400, :invalid_parameters, "The query parameters are invalid.", fields)
    end
  end

  def show(conn, %{"id" => id}) do
    case CreditNotes.get_listed_credit_note(id) do
      nil -> Error.send(conn, 404, :not_found, "No such credit note.")
      note -> json(conn, CreditNoteJSON.show(%{note: note}))
    end
  end

  def create(conn, %{"invoice_id" => invoice_id}) do
    Idempotency.run(conn, fn ->
      with {:invoice, %{} = invoice} <- {:invoice, Invoices.get_invoice(invoice_id)},
           {:ok, attrs} <- ActionParams.credit_note(conn.body_params),
           {:ok, note} <- CreditNotes.create_credit_note_for_invoice(invoice, attrs) do
        Audit.log_event(:credit_note_created, "CreditNote", note.id,
          api_key_id: conn.assigns.api_key.id,
          ip_address: conn.assigns.api_client_ip,
          details: %{"number" => note.note_number, "invoice_id" => invoice.id, "via" => "api"}
        )

        {201, CreditNoteJSON.show(%{note: CreditNotes.get_listed_credit_note(note.id)})}
      else
        {:invoice, nil} ->
          {404, %{error: %{code: "not_found", message: "No such invoice."}}}

        {:error, %Ecto.Changeset{} = changeset} ->
          invalid(Error.changeset_fields(changeset))

        {:error, fields} when is_map(fields) ->
          invalid(fields)
      end
    end)
  end

  defp invalid(fields),
    do:
      {422,
       %{error: %{code: "validation_failed", message: "The note is invalid.", fields: fields}}}
end
