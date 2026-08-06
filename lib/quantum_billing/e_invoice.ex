defmodule QuantumBilling.EInvoice do
  @moduledoc """
  The GST e-invoice (INV-01) data export.

  ## What this is, and what it is not

  An invoice becomes an *e-invoice* when the Invoice Registration Portal accepts
  it and returns an IRN and a digitally signed QR code. That requires GSTN
  credentials and a live call to the IRP; it cannot happen offline, and nothing
  here pretends otherwise.

  What this produces is the invoice's data, in the e-invoice schema's own
  vocabulary, as a file — for handing to an accountant or a GSP, for archiving,
  or as the input to a real IRP integration later. The generated file says so in
  a comment at the top, and the UI says so beside the button.

  Consequently:

    * No `Irn`, `AckNo` or `SignedQRCode` element is ever emitted. An unsigned QR
      in the place a GSTN-signed one belongs is not a placeholder, it is a forged
      compliance artefact.
    * The invoice's status is not changed. "E-Invoice Generated" means the IRP
      issued an IRN; setting it because somebody clicked Download would write a
      claim into the database that is false, and a compliance report would later
      repeat it.

  ## Validation refuses rather than guesses

  `validate/2` checks what the schema requires and returns every problem it
  finds, so a user fixes them in one pass. A silently wrong tax document is worse
  than no document, which is why the controller refuses to download when this
  fails.

  Note that `QuantumBilling.GST` validates a GSTIN by format only — it computes
  no checksum — so passing here means the file is well-formed, not that the IRP
  will accept it.
  """

  alias QuantumBilling.EInvoice.Payload
  alias QuantumBilling.GST
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

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
  Everything that would stop this invoice being submitted, in one list.
  """
  @spec validate(Invoice.t(), Organization.t()) :: :ok | {:error, [String.t()]}
  def validate(%Invoice{} = invoice, %Organization{} = organization) do
    problems =
      [
        status(invoice),
        document_type(invoice),
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

  # Not coerced to INV. A bill of supply is issued precisely because no tax is
  # charged, and an export invoice needs shipping details the schema asks for and
  # this application does not collect — calling either a tax invoice would be a
  # misstatement, not a formatting choice.
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

  # A buyer without a GSTIN is a B2C supply, which is legitimate — so the GSTIN
  # is only checked when one is present. The address parts are needed either way.
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
      unless(pincode?(invoice.client_pincode),
        do: "The client's six-digit PIN code is missing. Add it to the client and re-save the invoice."
      )
    ]
  end

  defp place_of_supply(%Invoice{place_of_supply: place}) do
    unless GST.state_code(place) do
      "The place of supply is missing or is not a recognised state."
    end
  end

  # HSN is mandatory in INV-01 and optional on a line item here, so this is the
  # failure most people will actually hit. The message points at the tool the
  # application already has for finding one.
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
end
