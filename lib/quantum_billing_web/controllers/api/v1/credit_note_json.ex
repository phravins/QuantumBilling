defmodule QuantumBillingWeb.API.V1.CreditNoteJSON do
  @moduledoc """
  A credit or debit note as the API shows it, built field by field like the
  other serializers. The client is named by id only: contact details come
  from `/clients`, behind `clients:read`.

  Amounts are integer minor units of `currency`, the invoice's, with
  `currency_exponent` decimal places.
  """

  alias QuantumBilling.CreditNotes.CreditNote

  @fields ~w(id number date type reason status currency currency_exponent amounts invoice
             client_id created_at updated_at)a

  @doc "The fields of a note, for the test that pins them."
  def fields, do: @fields

  def index(%{page: page}) do
    %{data: Enum.map(page.rows, &note/1), meta: QuantumBillingWeb.API.Pagination.meta(page)}
  end

  def show(%{note: note}), do: %{data: note(note)}

  defp note(%CreditNote{} = note) do
    currency = currency(note.invoice)

    %{
      id: note.id,
      number: note.note_number,
      # The note's date where the business is; GSTR-1 reports it by this.
      date: note.note_date,
      type: note.note_type |> to_string() |> String.downcase(),
      reason: note.reason,
      status: note.status,
      currency: currency,
      currency_exponent: QuantumBilling.Currency.exponent(currency),
      # Minor units, like every amount in the API.
      amounts: %{
        subtotal: note.subtotal,
        tax_total: note.tax_total,
        grand_total: note.grand_total
      },
      invoice: invoice(note.invoice),
      client_id: note.client_id,
      created_at: note.inserted_at,
      updated_at: note.updated_at
    }
  end

  defp invoice(%{id: id, invoice_number: number}), do: %{id: id, number: number}
  defp invoice(_none), do: nil

  defp currency(%{currency: currency}) when is_binary(currency), do: currency
  defp currency(_none), do: QuantumBilling.Currency.default()
end
