defmodule QuantumBillingWeb.InvoiceDocument do
  @moduledoc "A realistic sample invoice for previewing layouts (settings preview, design pad)."

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Settings.Organization

  @doc """
  A sample invoice, never saved. With an organisation, the seller details
  are filled from it; the buyer stays fictional.
  """
  def sample(organization \\ nil)

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
