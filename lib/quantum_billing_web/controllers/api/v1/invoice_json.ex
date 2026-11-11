defmodule QuantumBillingWeb.API.V1.InvoiceJSON do
  @moduledoc """
  An invoice as the API shows it, built field by field from the lists below.

  Never exposed: payment links and the public token (except the page URL with
  `invoices:payment_links`), signed e-invoice documents, internal fields, and
  the client's PAN, email and address (those need `clients:read`).
  `custom_fields` holds only the fields marked "Include in API".

  `tax_regime` is the regime the invoice was raised under. A VAT invoice has
  its VAT in `amounts.vat`, one `tax_breakdown` row per rate, and on each line
  the rate it snapshotted (`tax_rate_bp`, `tax_category`, `tax_name`); a GST
  invoice has the CGST/SGST/IGST split and each line's slab in `tax_rate`.
  """

  use QuantumBillingWeb, :verified_routes

  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Invoices.Invoice

  @fields ~w(id number type status invoice_date due_date payment_terms place_of_supply
             currency tax_regime reverse_charge tax_breakdown client amounts e_invoice
             remarks terms custom_fields created_at updated_at)a

  @item_fields ~w(position description hsn_sac quantity unit rate tax_rate tax_rate_id
                  tax_rate_bp tax_category tax_name amount custom_fields)a

  @doc "The top-level fields of an invoice, for the test that pins them."
  def fields, do: @fields

  @doc "The fields of a line item, for the test that pins them."
  def item_fields, do: @item_fields

  def index(%{page: page, api_key: key}) do
    %{
      data: Enum.map(page.rows, &invoice(&1, key, CustomFields.api_definitions("invoice"))),
      meta: QuantumBillingWeb.API.Pagination.meta(page)
    }
  end

  def show(%{invoice: invoice, api_key: key}) do
    definitions = CustomFields.api_definitions("invoice")
    %{data: invoice |> invoice(key, definitions) |> Map.put(:items, items(invoice))}
  end

  defp invoice(%Invoice{} = invoice, %ApiKey{} = key, definitions) do
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
      tax_regime: invoice.tax_regime,
      reverse_charge: invoice.reverse_charge,
      tax_breakdown: Enum.map(invoice.tax_breakdown || [], &breakdown_row/1),
      client: %{
        id: invoice.client_id,
        name: invoice.client_name,
        gstin: invoice.client_gstin,
        tax_number: invoice.client_tax_number,
        state: invoice.client_state
      },
      # Paise, as stored: integers, so no client has to guess at float rounding
      # on a tax figure. 118000 is ₹1,180.00.
      amounts: %{
        taxable_value: invoice.taxable_value,
        cgst: invoice.cgst_amount,
        sgst: invoice.sgst_amount,
        igst: invoice.igst_amount,
        cess: invoice.cess_amount,
        vat: invoice.vat_amount,
        round_off: invoice.round_off,
        grand_total: invoice.grand_total
      },
      # `mode` is "demo" for an IRN made by the sandbox, which was never filed
      # with the government; "live" for a real one; nil before registration.
      e_invoice: %{
        irn: invoice.irn,
        ack_number: invoice.ack_number,
        ack_date: invoice.ack_date,
        mode: invoice.irn && invoice.irn_mode
      },
      remarks: invoice.remarks,
      terms: invoice.terms,
      custom_fields: CustomFields.visible_values(invoice.custom_fields, definitions),
      created_at: invoice.inserted_at,
      updated_at: invoice.updated_at
    }
    |> maybe_payment_url(invoice, key)
  end

  defp breakdown_row(row) do
    %{
      name: row["name"],
      category: row["category"],
      rate_bp: row["rate_bp"],
      taxable: row["taxable"],
      tax: row["tax"]
    }
  end

  defp maybe_payment_url(json, invoice, key) do
    if ApiKey.has_scope?(key, "invoices:payment_links") and is_binary(invoice.public_token) do
      # The slugged link: it names the business, which the bare `/pay/` form
      # (kept for links sent before there were several) cannot.
      slug = QuantumBilling.Repo.business().slug
      Map.put(json, :payment_url, url(~p"/p/#{slug}/#{invoice.public_token}"))
    else
      json
    end
  end

  defp items(%Invoice{items: items}) when is_list(items) do
    definitions = CustomFields.api_definitions("invoice_item")

    items
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn item ->
      %{
        position: item.position,
        description: item.description,
        hsn_sac: item.hsn_sac,
        # A decimal, as a string ("2.5"): quantities can be fractional, and a
        # JSON float would round them.
        quantity: item.quantity,
        unit: item.unit,
        # Paise, like every amount.
        rate: item.rate,
        tax_rate: item.tax_rate,
        # VAT lines: the rate chosen and what it was when saved (750 = 7.5%).
        tax_rate_id: item.tax_rate_id,
        tax_rate_bp: item.tax_rate_bp,
        tax_category: item.tax_category,
        tax_name: item.tax_name,
        amount: item.amount,
        custom_fields: CustomFields.visible_values(item.custom_fields, definitions)
      }
    end)
  end

  defp items(_not_loaded), do: []
end
