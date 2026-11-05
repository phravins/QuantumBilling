defmodule QuantumBilling.Payments.QRCode do
  @moduledoc """
  QR codes for UPI payment and the signed e-invoice payload.

  `EQRCode.encode/1` raises on bad input, so it is wrapped. A payment QR needs a
  real UPI VPA from Settings › Integrations; without one, none is drawn.
  """

  require Logger

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Money
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  # name@handle; an email address is the mistake this catches.
  @vpa_format ~r/^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$/

  @doc """
  The UPI intent URI for an invoice, or `{:error, reason}`. Also offered as a link on phones.
  """
  def upi_uri(invoice, organization \\ nil)

  def upi_uri(%Invoice{} = invoice, nil),
    do: upi_uri(invoice, Settings.get_organization())

  def upi_uri(%Invoice{} = invoice, %Organization{} = organization) do
    case payee_vpa(organization) do
      nil ->
        {:error, :no_upi_id}

      vpa ->
        name = payee_name(organization, invoice)

        query =
          [
            pa: vpa,
            pn: name,
            am: amount(invoice.grand_total),
            cu: invoice.currency || "INR",
            tn: note(invoice),
            tr: reference(invoice)
          ]
          |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
          |> Enum.map_join("&", fn {key, value} -> "#{key}=#{escape(value)}" end)

        {:ok, "upi://pay?" <> query}
    end
  end

  def upi_uri(_invoice, _organization), do: {:error, :no_upi_id}

  @doc "Whether a payment QR can be drawn, so a page can explain why not."
  def upi_configured?(organization \\ nil)

  def upi_configured?(nil), do: upi_configured?(Settings.get_organization())
  def upi_configured?(%Organization{} = organization), do: payee_vpa(organization) != nil
  def upi_configured?(_organization), do: false

  @doc """
  An inline SVG of the invoice's UPI payment QR, or `""` when no UPI ID is
  configured.
  """
  def generate_invoice_upi_qr(%Invoice{} = invoice, opts \\ []) do
    case upi_uri(invoice, Keyword.get(opts, :organization)) do
      {:ok, uri} -> generate_svg(uri, opts)
      {:error, _reason} -> ""
    end
  end

  @doc """
  An inline SVG QR of any string, or `""` if it can't be encoded (empty or over 2,952 characters).
  """
  def generate_svg(content, opts \\ [])

  def generate_svg(content, opts) when is_binary(content) and content != "" do
    svg_options =
      Keyword.merge(
        [width: Keyword.get(opts, :width, 200), background_color: "#ffffff", color: "#18181b"],
        Keyword.take(opts, [:background_color, :color])
      )

    content
    |> EQRCode.encode()
    |> EQRCode.svg(svg_options)
    # The XML declaration is invalid once the SVG is inlined.
    |> String.replace(~r/<\?xml[^>]*\?>/, "")
    |> String.trim()
  rescue
    error ->
      Logger.warning(
        "[QRCode] could not encode #{byte_size(content)} bytes: " <>
          Exception.message(error)
      )

      ""
  end

  def generate_svg(_content, _opts), do: ""

  defp payee_vpa(%Organization{upi_vpa: vpa}) when is_binary(vpa) do
    trimmed = String.trim(vpa)

    if Regex.match?(@vpa_format, trimmed), do: trimmed, else: nil
  end

  defp payee_vpa(_organization), do: nil

  defp payee_name(%Organization{} = organization, %Invoice{} = invoice) do
    presence(organization.upi_payee_name) || presence(organization.trade_name) ||
      presence(organization.company_name) || presence(invoice.company_name) || "QuantumBilling"
  end

  # Paise in, rupees with two decimals out.
  defp amount(nil), do: nil
  defp amount(paise) when is_integer(paise) and paise > 0, do: Money.to_input(paise)
  defp amount(_paise), do: nil

  defp note(%Invoice{invoice_number: number}) when is_binary(number),
    do: String.slice("Invoice " <> number, 0, 50)

  defp note(_invoice), do: "Invoice"

  defp reference(%Invoice{invoice_number: number}) when is_binary(number) do
    number |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(0, 35)
  end

  defp reference(_invoice), do: nil

  # Not encode_www_form/1: several UPI apps show "+" literally.
  defp escape(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
