defmodule QuantumBilling.Payments.QRCode do
  @moduledoc """
  Generates vector SVG QR codes for UPI payments and invoice URLs.
  """

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings

  @doc """
  Generates an inline SVG string for an invoice's UPI payment QR code.
  Reads organization VPA or defaults to company email/name.
  """
  def generate_invoice_upi_qr(%Invoice{} = invoice) do
    org = Settings.get_organization()
    vpa = (org.email && String.trim(org.email)) || "billing@quantumbilling.in"
    name = org.company_name || invoice.company_name || "QuantumBilling"

    upi_url =
      "upi://pay?pa=#{URI.encode(vpa)}&pn=#{URI.encode(name)}&am=#{invoice.grand_total}&tn=#{invoice.invoice_number}&cu=INR"

    case EQRCode.encode(upi_url) do
      {:ok, qr} ->
        qr
        |> EQRCode.svg()
        |> String.replace(~r/<\?xml[^>]+\?>/, "")

      _ ->
        ""
    end
  end

  @doc """
  Generates an inline SVG string for a generic text or URL string.
  """
  def generate_svg(content) when is_binary(content) do
    case EQRCode.encode(content) do
      {:ok, qr} ->
        qr
        |> EQRCode.svg()
        |> String.replace(~r/<\?xml[^>]+\?>/, "")

      _ ->
        ""
    end
  end
end
