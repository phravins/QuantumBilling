defmodule QuantumBillingWeb.API.V1.QuotationJSON do
  @moduledoc """
  A quotation as the API shows it, built field by field from the lists below.

  `status` is what the screens show: Draft, Sent, Accepted, Declined, or
  Expired for an open quotation past `valid_until`. `invoice_id` is the
  invoice it was converted into, else nil. Amounts are integer minor units
  of `currency`, with `currency_exponent` decimal places (3 for KWD, BHD and
  OMR, else 2). The client
  link (`public_url`, once the quotation has one) needs `quotations:write`,
  since whoever holds it can accept the quotation.
  `custom_fields` holds only the fields marked "Include in API".
  """

  use QuantumBillingWeb, :verified_routes

  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.CustomFields
  alias QuantumBilling.QuotationNotifier
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation

  @fields ~w(id number status quotation_date valid_until place_of_supply currency
             currency_exponent tax_regime reverse_charge tax_breakdown client amounts invoice_id remarks
             terms custom_fields created_at updated_at)a

  @item_fields ~w(position description hsn_sac quantity unit rate tax_rate tax_rate_id
                  tax_rate_bp tax_category tax_name amount custom_fields)a

  @doc "The top-level fields of a quotation, for the test that pins them."
  def fields, do: @fields

  @doc "The fields of a line item, for the test that pins them."
  def item_fields, do: @item_fields

  def index(%{page: page, api_key: key}) do
    definitions = CustomFields.api_definitions("quotation")
    today = Quotations.today()

    %{
      data: Enum.map(page.rows, &quotation(&1, key, definitions, today)),
      meta: QuantumBillingWeb.API.Pagination.meta(page)
    }
  end

  def show(%{quotation: quotation, api_key: key}) do
    definitions = CustomFields.api_definitions("quotation")

    %{
      data:
        quotation
        |> quotation(key, definitions, Quotations.today())
        |> Map.put(:items, items(quotation))
    }
  end

  defp quotation(%Quotation{} = quotation, %ApiKey{} = key, definitions, today) do
    %{
      id: quotation.id,
      number: quotation.number,
      status: Quotation.effective_status(quotation, today),
      quotation_date: quotation.quotation_date,
      valid_until: quotation.valid_until,
      place_of_supply: quotation.place_of_supply,
      currency: quotation.currency,
      currency_exponent: QuantumBilling.Currency.exponent(quotation.currency),
      tax_regime: quotation.tax_regime,
      reverse_charge: quotation.reverse_charge,
      tax_breakdown: Enum.map(quotation.tax_breakdown || [], &breakdown_row/1),
      client: %{
        id: quotation.client_id,
        name: quotation.client_name,
        gstin: quotation.client_gstin,
        tax_number: quotation.client_tax_number,
        state: quotation.client_state
      },
      amounts: %{
        taxable_value: quotation.taxable_value,
        cgst: quotation.cgst_amount,
        sgst: quotation.sgst_amount,
        igst: quotation.igst_amount,
        cess: quotation.cess_amount,
        vat: quotation.vat_amount,
        round_off: quotation.round_off,
        grand_total: quotation.grand_total
      },
      invoice_id: invoice_id(quotation),
      remarks: quotation.remarks,
      terms: quotation.terms,
      custom_fields: CustomFields.visible_values(quotation.custom_fields, definitions),
      created_at: quotation.inserted_at,
      updated_at: quotation.updated_at
    }
    |> maybe_public_url(quotation, key)
  end

  defp invoice_id(%Quotation{invoice: %{id: id}}), do: id
  defp invoice_id(_quotation), do: nil

  defp maybe_public_url(json, quotation, key) do
    case ApiKey.has_scope?(key, "quotations:write") && QuotationNotifier.public_url(quotation) do
      url when is_binary(url) -> Map.put(json, :public_url, url)
      _no_link -> json
    end
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

  defp items(%Quotation{items: items}) when is_list(items) do
    definitions = CustomFields.api_definitions("quotation_item")

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
