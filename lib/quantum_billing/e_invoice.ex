defmodule QuantumBilling.EInvoice do
  @moduledoc """
  The GST e-invoice (INV-01) data export, as a file.

  This is the invoice's data in the e-invoice schema, not a registered
  e-invoice: no `Irn`, `AckNo` or `SignedQRCode` is emitted and the invoice
  status is not changed. `validate/2` returns every problem at once. GSTINs are
  checked by format only, so passing doesn't guarantee the IRP accepts it.
  """

  alias QuantumBilling.EInvoice.Payload
  alias QuantumBilling.GST
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Money
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Tax

  @doc """
  The XML for `invoice`, or every reason it cannot be produced.
  """
  @spec xml_for(Invoice.t()) :: {:ok, binary()} | {:error, [String.t()]}
  def xml_for(%Invoice{} = invoice) do
    organization = Settings.get_organization()

    case validate(invoice, organization) do
      :ok ->
        xml =
          invoice
          |> Payload.build(organization)
          |> Saxy.encode!(version: "1.0", encoding: :utf8)

        {:ok, xml <> "\n"}

      {:error, problems} ->
        {:error, problems}
    end
  end

  @doc """
  Converts the invoice into the official NIC JSON payload format for the IRP API.
  """
  def to_json(%Invoice{} = invoice) do
    organization = Settings.get_organization()
    export? = export?(invoice)

    %{
      "Version" => "1.1",
      "TranDetails" => %{
        "TaxSch" => "GST",
        "SupTyp" => supply_type(invoice),
        "RegRev" => if(Invoice.gst_reverse_charge?(invoice), do: "Y", else: "N")
      },
      "DocDetails" => %{
        "Typ" => "INV",
        "No" => invoice.invoice_number,
        "Dt" => to_string(invoice.invoice_date)
      },
      "SellerDetails" => %{
        "Gstin" => organization.gstin,
        "LglName" => organization.company_name,
        "Addr1" => organization.address,
        "Loc" => organization.city,
        "Pin" => organization.pincode,
        "Stcd" => GST.state_code(organization.state)
      },
      "BuyerDetails" => %{
        "Gstin" => if(export?, do: "URP", else: invoice.client_gstin),
        "LglName" => invoice.client_name,
        "Pos" => if(export?, do: "96", else: GST.state_code(invoice.place_of_supply)),
        "Addr1" => invoice.client_billing_address,
        "Loc" => invoice.client_city,
        "Pin" => if(export?, do: 999_999, else: invoice.client_pincode),
        "Stcd" =>
          if(export?,
            do: "96",
            else: GST.state_code(invoice.client_state || invoice.place_of_supply)
          )
      },
      "ItemList" =>
        Enum.map(invoice.items || [], fn item ->
          %{
            "SlNo" => to_string(item.position || 1),
            "PrdDesc" => item.description,
            "HsnCd" => item.hsn_sac,
            "Qty" => quantity(item.quantity),
            "Unit" => item.unit,
            "UnitPrice" => rupees(inr_paise(item.rate, invoice)),
            "TotAmt" => rupees(inr_paise(item.amount, invoice)),
            "GstRt" => item.tax_rate,
            "TotItemVal" => rupees(inr_paise(item.amount, invoice))
          }
        end),
      "ValDetails" => %{
        # On a reverse-charge invoice the tax is reported though not charged:
        # the charged columns are 0 and the recipient's tax is in rc_*.
        "AssVal" => rupees(inr_paise(invoice.taxable_value, invoice)),
        "CgstVal" => rupees(inr_paise(Payload.reported_tax(invoice, :cgst), invoice)),
        "SgstVal" => rupees(inr_paise(Payload.reported_tax(invoice, :sgst), invoice)),
        "IgstVal" => rupees(inr_paise(Payload.reported_tax(invoice, :igst), invoice)),
        "CesVal" => rupees(inr_paise(Payload.reported_tax(invoice, :cess), invoice)),
        "RndOffAmt" => rupees(inr_paise(invoice.round_off, invoice)),
        "TotInvVal" => rupees(inr_paise(invoice.grand_total, invoice))
      }
    }
    |> maybe_export_details(invoice)
  end

  def export?(%Invoice{export_type: type}), do: type in ["EXPORT_WITH_PAY", "EXPORT_WITHOUT_PAY"]

  def eligible?(%Invoice{} = invoice), do: export?(invoice) or present?(invoice.client_gstin)

  def inr_paise(nil, _invoice), do: 0
  def inr_paise(amount, %Invoice{currency: currency}) when currency in [nil, "INR"], do: amount

  def inr_paise(amount, %Invoice{} = invoice) do
    rate = invoice.exchange_rate || 1
    rate = if is_float(rate), do: Decimal.from_float(rate), else: rate
    amount |> Decimal.new() |> Decimal.mult(rate) |> Decimal.round(0) |> Decimal.to_integer()
  end

  def supply_type(%Invoice{export_type: "EXPORT_WITH_PAY"}), do: "EXPWP"
  def supply_type(%Invoice{export_type: "EXPORT_WITHOUT_PAY"}), do: "EXPWOP"
  def supply_type(%Invoice{}), do: "B2B"

  defp maybe_export_details(payload, invoice) do
    if export?(invoice) do
      Map.put(payload, "ExpDetails", %{
        "ForCur" => invoice.currency,
        "CntCode" => invoice.client_country,
        "RefClm" => if(invoice.export_type == "EXPORT_WITH_PAY", do: "Y", else: "N")
      })
    else
      payload
    end
  end

  # The IRP takes rupees and quantities as JSON numbers; amounts are stored in paise.
  defp rupees(nil), do: 0
  defp rupees(paise) when is_integer(paise), do: paise / 100

  defp quantity(quantity) do
    case Money.quantity(quantity) do
      nil -> 0
      decimal -> Decimal.to_float(decimal)
    end
  end

  @doc """
  Everything that would stop this invoice being submitted, in one list.
  """
  @spec validate(Invoice.t(), Organization.t()) :: :ok | {:error, [String.t()]}
  def validate(%Invoice{tax_regime: "vat"}, _organization),
    do: {:error, [Tax.gst_only_message(:e_invoice)]}

  def validate(%Invoice{} = invoice, %Organization{} = organization) do
    if Organization.vat?(organization),
      do: {:error, [Tax.gst_only_message(:e_invoice)]},
      else: gst_problems(invoice, organization)
  end

  defp gst_problems(invoice, organization) do
    problems =
      [
        status(invoice),
        document_type(invoice),
        eligibility(invoice),
        export_tax(invoice),
        seller(organization),
        buyer(invoice),
        place_of_supply(invoice),
        items(invoice)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp status(%Invoice{status: "Cancelled"}) do
    "This invoice is cancelled, so there is nothing to report."
  end

  defp status(_invoice), do: nil

  defp eligibility(invoice) do
    unless eligible?(invoice), do: "E-invoicing is not applicable to domestic B2C supplies."
  end

  defp export_tax(invoice) do
    if export?(invoice) do
      cond do
        Payload.reported_tax(invoice, :cgst) != 0 or Payload.reported_tax(invoice, :sgst) != 0 ->
          "An export invoice must not contain CGST or SGST. Correct the invoice before requesting an IRN."

        invoice.export_type == "EXPORT_WITHOUT_PAY" and Payload.reported_tax(invoice, :igst) != 0 ->
          "An export without payment must not contain IGST. Correct the invoice before requesting an IRN."

        true ->
          nil
      end
    end
  end

  # Not coerced to INV: calling either a tax invoice would misstate it.
  defp document_type(%Invoice{invoice_type: type}) do
    if Payload.type_code(type) do
      nil
    else
      "A #{type} cannot be reported as an e-invoice — only " <>
        Enum.join(Payload.exportable_types(), ", ") <> " can."
    end
  end

  defp seller(%Organization{} = organization) do
    [
      unless(GST.valid_gstin?(organization.gstin),
        do: "Your GSTIN is missing or invalid. Add it in Settings → General."
      ),
      unless(present?(organization.company_name), do: "Your company name is missing."),
      unless(present?(organization.address), do: "Your address is missing."),
      unless(present?(organization.city),
        do: "Your city is missing. Add it in Settings → General."
      ),
      unless(pincode?(organization.pincode),
        do: "Your six-digit PIN code is missing. Add it in Settings → General."
      ),
      unless(GST.state_code(organization.state), do: "Your state is missing.")
    ]
  end

  # GSTIN checked only when present; B2C buyers have none.
  defp buyer(%Invoice{} = invoice) do
    [
      unless(present?(invoice.client_name), do: "The client's name is missing."),
      if(present?(invoice.client_gstin) and not GST.valid_gstin?(invoice.client_gstin),
        do: "The client's GSTIN is not valid."
      ),
      unless(present?(invoice.client_billing_address), do: "The client's address is missing."),
      unless(present?(invoice.client_city),
        do: "The client's city is missing. Add it to the client and re-save the invoice."
      ),
      unless(export?(invoice) or pincode?(invoice.client_pincode),
        do:
          "The client's six-digit PIN code is missing. Add it to the client and re-save the invoice."
      ),
      if(export?(invoice) and not country_code?(invoice.client_country),
        do: "The export client's two-letter country code is missing."
      )
    ]
  end

  defp place_of_supply(%Invoice{place_of_supply: place} = invoice) do
    unless export?(invoice) or GST.state_code(place) do
      "The place of supply is missing or is not a recognised state."
    end
  end

  # Must come before the is_list clause, which [] also matches.
  defp items(%Invoice{items: []}), do: "This invoice has no line items."

  defp items(%Invoice{items: items}) when is_list(items) do
    missing =
      items
      |> Enum.with_index(1)
      |> Enum.reject(fn {item, _index} -> present?(item.hsn_sac) end)
      |> Enum.map(fn {_item, index} -> index end)

    case missing do
      [] ->
        nil

      lines ->
        "Every line needs an HSN or SAC code; #{numbered(lines)} " <>
          "#{if length(lines) == 1, do: "has", else: "have"} none. " <>
          "The HSN Finder can look them up."
    end
  end

  defp items(_invoice), do: "This invoice has no line items."

  defp numbered([one]), do: "line #{one}"
  defp numbered(lines), do: "lines " <> Enum.map_join(lines, ", ", &to_string/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp pincode?(value) when is_binary(value), do: Regex.match?(~r/^\d{6}$/, value)
  defp pincode?(_value), do: false

  defp country_code?(value) when is_binary(value),
    do: Regex.match?(~r/^[A-Z]{2}$/, value) and value != "IN"

  defp country_code?(_value), do: false
end
