defmodule QuantumBilling.CreditNotes do
  @moduledoc """
  Context module for managing Credit Notes and Debit Notes.
  """
  import Ecto.Query, warn: false
  alias QuantumBilling.Repo
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Money

  # Notes on binned invoices are left out; a left join keeps notes with no invoice.
  def list_credit_notes do
    CreditNote
    |> join(:left, [n], i in assoc(n, :invoice))
    |> where([_n, i], is_nil(i.deleted_at))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Repo.preload([:invoice, :client])
  end

  @doc """
  One page of notes for the API, newest first, keyset-paged below
  `:before_id` (see `QuantumBilling.Paging.keyset/3`). Notes on binned invoices
  are left out, as from `list_credit_notes/0`.

  Options: `:before_id`, `:per_page` (1..100), `:invoice_id`.
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, 25) |> max(1) |> min(100)

    listed_query()
    |> invoice_where(Keyword.get(opts, :invoice_id))
    |> QuantumBilling.Paging.keyset(Keyword.get(opts, :before_id), per_page)
    |> then(fn result -> %{result | rows: Repo.preload(result.rows, :invoice)} end)
  end

  @doc "A note by id, on the same terms as `page/1` lists it, or `nil`."
  def get_listed_credit_note(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        listed_query() |> where([n], n.id == ^id) |> Repo.one() |> Repo.preload(:invoice)

      _not_an_id ->
        nil
    end
  end

  defp listed_query do
    from n in CreditNote,
      left_join: i in assoc(n, :invoice),
      where: is_nil(i.deleted_at)
  end

  defp invoice_where(query, nil), do: query
  defp invoice_where(query, invoice_id), do: where(query, [n], n.invoice_id == ^invoice_id)

  def get_credit_note!(id) do
    CreditNote
    |> Repo.get!(id)
    |> Repo.preload([:invoice, :client])
  end

  @doc """
  Raises a note against `invoice`.

  Amounts in `attrs` are rupees, as typed into the note form; any left out
  default to the invoice's own figures.
  """
  def create_credit_note_for_invoice(%Invoice{} = invoice, attrs \\ %{}) do
    note_type = Map.get(attrs, "note_type") || Map.get(attrs, :note_type, "Credit")
    prefix = if note_type == "Credit", do: "CN", else: "DN"
    note_number = "#{prefix}-#{invoice.invoice_number}-#{System.unique_integer([:positive])}"

    subtotal =
      Map.get(attrs, "subtotal") ||
        Map.get(attrs, :subtotal, Money.to_rupees_decimal(invoice.taxable_value))

    tax_total =
      Map.get(attrs, "tax_total") ||
        Map.get(
          attrs,
          :tax_total,
          Money.to_rupees_decimal(
            (invoice.cgst_amount || 0) + (invoice.sgst_amount || 0) + (invoice.igst_amount || 0)
          )
        )

    grand_total =
      Map.get(attrs, "grand_total") ||
        Map.get(attrs, :grand_total, Money.to_rupees_decimal(invoice.grand_total))

    reason = Map.get(attrs, "reason") || Map.get(attrs, :reason, "Order modification / refund")

    params = %{
      note_number: note_number,
      note_type: note_type,
      invoice_id: invoice.id,
      client_id: invoice.client_id,
      reason: reason,
      subtotal: subtotal,
      tax_total: tax_total,
      grand_total: grand_total,
      status: "Issued"
    }

    %CreditNote{}
    |> CreditNote.changeset(params)
    |> Repo.insert()
    |> case do
      {:ok, note} = result ->
        QuantumBilling.Webhooks.publish("credit_note.created", note.id)
        result

      error ->
        error
    end
  end
end
