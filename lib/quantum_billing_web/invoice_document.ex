defmodule QuantumBillingWeb.InvoiceDocument do
  @moduledoc "A realistic sample invoice for previewing layouts (settings preview, design pad)."

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Tax

  @doc """
  A sample invoice, never saved. With an organisation, the seller details
  are filled from it; the buyer stays fictional.
  """
  def sample(organization \\ nil)

  def sample(%Organization{tax_regime: "vat"} = organization) do
    seller = organization |> seller_fields() |> Keyword.drop([:company_gstin, :company_state])
    tax_number = presence(organization.vat_number)

    organization
    |> vat_sample()
    |> struct(seller)
    |> struct(if tax_number, do: [company_tax_number: tax_number], else: [])
  end

  def sample(%Organization{} = organization) do
    seller = seller_fields(organization)

    # Seller's own state, so the hard-coded CGST + SGST split stays correct.
    place = seller[:company_state] || "Maharashtra (27)"

    sample(nil)
    |> struct(seller)
    |> struct(%{place_of_supply: place, client_state: place})
  end

  def sample(nil) do
    %Invoice{
      invoice_number: "INV-0042",
      invoice_type: "Tax Invoice",
      invoice_date: ~D[2026-04-18],
      due_date: ~D[2026-05-18],
      payment_terms: "Net 30 Days",
      place_of_supply: "Maharashtra (27)",
      company_name: "Your Company",
      company_address: "221B Example Street\nMumbai - 400001",
      company_gstin: "27AABCA1234A1Z5",
      company_state: "Maharashtra (27)",
      client_name: "Northwind Traders",
      client_gstin: "27AAACN1234C1ZP",
      client_billing_address: "14 Harbour Road\nMumbai - 400002",
      client_email: "accounts@northwind.example",
      client_state: "Maharashtra (27)",
      taxable_value: 2_400_000,
      cgst_amount: 216_000,
      sgst_amount: 216_000,
      igst_amount: 0,
      cess_amount: 0,
      round_off: 0,
      grand_total: 2_832_000,
      total_items: 2,
      total_quantity: Decimal.new(3),
      remarks: "Delivered against PO-8842.",
      terms: "Payable within 30 days.",
      status: "Draft",
      items: [
        %InvoiceItem{
          description: "Design retainer",
          hsn_sac: "998311",
          quantity: Decimal.new(1),
          unit: "Nos",
          rate: 1_800_000,
          tax_rate: 18,
          amount: 1_800_000,
          position: 0
        },
        %InvoiceItem{
          description: "Support hours",
          hsn_sac: "998313",
          quantity: Decimal.new(2),
          unit: "Hrs",
          rate: 300_000,
          tax_rate: 18,
          amount: 600_000,
          position: 1
        }
      ]
    }
  end

  @doc """
  The design pad's sample: fictional throughout, under the business's regime
  and currency, so a VAT business designs against VAT lines.
  """
  def pad_sample(%Organization{tax_regime: "vat"} = organization), do: vat_sample(organization)
  def pad_sample(_organization), do: sample(nil)

  # Two lines, one at the country's standard rate and one zero-rated, totalled
  # by the real VAT engine.
  defp vat_sample(%Organization{} = organization) do
    country = organization.vat_country
    {name, category, rate_bp} = standard_preset(country)

    items = [
      %InvoiceItem{
        description: "Design retainer",
        quantity: Decimal.new(1),
        unit: "Nos",
        rate: 1_800_000,
        tax_rate: 0,
        tax_rate_bp: rate_bp,
        tax_category: category,
        tax_name: name,
        amount: 1_800_000,
        position: 0
      },
      %InvoiceItem{
        description: "Export freight",
        quantity: Decimal.new(2),
        unit: "Hrs",
        rate: 300_000,
        tax_rate: 0,
        tax_rate_bp: 0,
        tax_category: "zero",
        tax_name: "Zero-rated",
        amount: 600_000,
        position: 1
      }
    ]

    round? = Organization.round_to_whole_units?(organization)

    totals =
      Tax.totals(items, %{regime: "vat", reverse_charge: false, round_to_whole_units: round?})

    %Invoice{
      sample(nil)
      | tax_regime: "vat",
        currency: Organization.currency_code(organization),
        round_to_whole_units: round?,
        place_of_supply: nil,
        company_address: "Office 1204, Example Tower",
        company_gstin: nil,
        company_state: nil,
        company_tax_number: sample_tax_number(country, "1001234567"),
        client_gstin: nil,
        client_state: nil,
        client_billing_address: "14 Harbour Road",
        client_tax_number: sample_tax_number(country, "1009876543"),
        items: items
    }
    |> struct(totals)
  end

  defp standard_preset(country) do
    country
    |> Tax.presets()
    |> Enum.find({"Standard", "standard", 500}, fn {_name, category, bp} ->
      category == "standard" and bp > 0
    end)
  end

  # A number in the country's shape, for show only.
  defp sample_tax_number(country, digits) when country in ["AE", "SA", "BH"],
    do: digits <> "00003"

  defp sample_tax_number("GB", digits), do: "GB" <> String.slice(digits, 0, 9)
  defp sample_tax_number("OM", digits), do: "OM" <> digits
  defp sample_tax_number(country, digits) when is_binary(country), do: country <> digits
  defp sample_tax_number(_country, digits), do: digits

  # Only filled fields, so blanks keep the placeholder.
  defp seller_fields(%Organization{} = organization) do
    address =
      [organization.address, "#{organization.city} #{organization.pincode}"]
      |> Enum.map(&presence/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    [
      company_name: presence(organization.company_name),
      company_address: presence(address),
      company_gstin: presence(organization.gstin),
      company_state: presence(organization.state)
    ]
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
