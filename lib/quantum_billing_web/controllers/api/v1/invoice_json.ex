defmodule QuantumBillingWeb.API.V1.InvoiceJSON do
  @moduledoc """
  An invoice as the API shows it.

  Built field by field from the lists below. Nothing is ever produced by
  serialising the struct wholesale, so a column added to `invoices` later does
  not quietly become part of the API — and the test that pins these lists
  fails until someone decides that it should.

  Never exposed, on purpose:

    * `public_token`, `razorpay_payment_url`, `razorpay_payment_link_id` — each
      is a bearer link to the customer's payment page. The page URL is shown
      only to a key holding `invoices:payment_links`.
    * `signed_invoice`, `signed_qr_code` — the government-signed documents. The
      IRN, which is printed on the invoice anyway, is enough to reference one.
    * `layout_xml`, `template_id`, `deleted_at`, `razorpay_payment_id` —
      internal.
    * the client's PAN, email and address. An invoice carries a client
      summary; contact details come from `/clients`, which needs
      `clients:read`. A key granted invoices cannot harvest customer emails
      through them.
  """

  use QuantumBillingWeb, :verified_routes

  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.Invoices.Invoice

  @fields ~w(id number type status invoice_date due_date payment_terms place_of_supply
             currency client amounts e_invoice remarks terms created_at updated_at)a

  @item_fields ~w(position description hsn_sac quantity unit rate tax_rate amount)a

  @doc "The top-level fields of an invoice, for the test that pins them."
  def fields, do: @fields

  @doc "The fields of a line item, for the test that pins them."
  def item_fields, do: @item_fields

  def index(%{page: page, api_key: key}) do
    %{
      data: Enum.map(page.rows, &invoice(&1, key)),
      meta: Map.take(page, [:page, :per_page, :total, :total_pages])
    }
  end

  def show(%{invoice: invoice, api_key: key}) do
    %{data: invoice |> invoice(key) |> Map.put(:items, items(invoice))}
  end

  defp invoice(%Invoice{} = invoice, %ApiKey{} = key) do
    %{
      id: invoice.id,
      number: invoice.invoice_number,
      type: invoice.invoice_type,
      status: invoice.status,
      invoice_date: invoice.invoice_date,
      due_date: invoice.due_date,
      payment_terms: invoice.payment_terms,
      place_of_supply: invoice.place_of_supply,
      currency: invoice.currency,
      client: %{
        id: invoice.client_id,
        name: invoice.client_name,
        gstin: invoice.client_gstin,
        state: invoice.client_state
      },
      # Whole rupees, as stored. Integers, so no client has to guess at float
      # rounding on a tax figure.
      amounts: %{
        taxable_value: invoice.taxable_value,
        cgst: invoice.cgst_amount,
        sgst: invoice.sgst_amount,
        igst: invoice.igst_amount,
        cess: invoice.cess_amount,
        round_off: invoice.round_off,
        grand_total: invoice.grand_total
      },
      e_invoice: %{irn: invoice.irn, ack_number: invoice.ack_number, ack_date: invoice.ack_date},
      remarks: invoice.remarks,
      terms: invoice.terms,
      created_at: invoice.inserted_at,
      updated_at: invoice.updated_at
    }
    |> maybe_payment_url(invoice, key)
  end

  defp maybe_payment_url(json, invoice, key) do
    if ApiKey.has_scope?(key, "invoices:payment_links") and is_binary(invoice.public_token) do
      Map.put(json, :payment_url, url(~p"/pay/#{invoice.public_token}"))
    else
      json
    end
  end

  defp items(%Invoice{items: items}) when is_list(items) do
    items
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn item ->
      %{
        position: item.position,
        description: item.description,
        hsn_sac: item.hsn_sac,
        quantity: item.quantity,
        unit: item.unit,
        rate: item.rate,
        tax_rate: item.tax_rate,
        amount: item.amount
      }
    end)
  end

  defp items(_not_loaded), do: []
end
