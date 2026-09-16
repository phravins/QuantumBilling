defmodule QuantumBilling.Payments.QRCode do
  @moduledoc """
  QR codes for UPI payment and for the government's signed e-invoice payload.

  ## Two things had to be true for these to work

  `EQRCode.encode/1` returns the matrix itself and raises on input it cannot
  encode — it never returns `{:ok, _}`. Matching on `{:ok, qr}` therefore fell
  through to the catch-all on every single call, and every QR on the invoice
  page, the public payment page and the dashboard rendered as an empty string.
  That is fixed here, and the encode is wrapped rather than matched, because
  raising is how this library reports "too long" and "nil".

  The payment QR also has to be a *UPI intent*, not a picture of an email
  address. It used to fall back to the organisation's contact address as the
  payee VPA, which every UPI app rejects: a VPA is `name@handle` issued by a
  bank or PSP, and `accounts@company.com` is not one. A QR that scans into an
  error is worse than no QR, so without a configured VPA
  (Settings › Integrations) none is drawn and the page says why.
  """

  require Logger

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  # `name@handle`: the same shape every UPI app accepts, and deliberately not a
  # full email pattern — a VPA has no dots-in-domain requirement and an address
  # with one is the mistake this is here to catch.
  @vpa_format ~r/^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$/

  @doc """
  The UPI intent URI for an invoice, or `{:error, reason}`.

  Public because the public payment page also offers it as a link — on a phone
  the link opens the UPI app directly, which is more useful than a QR code the
  same phone would have to photograph.
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

  @doc """
  Whether a payment QR can be drawn at all.

  Lets a page explain the absence — "add a UPI ID in Settings" — instead of
  leaving a blank square where a QR should be.
  """
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
  An inline SVG QR of any string — a signed e-invoice payload, a URL.

  Returns `""` for content that cannot be encoded (empty, or past the format's
  2,952-character ceiling) rather than taking the page down with it: a QR is
  decoration on a page that has the same information in text beside it.
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
    # The XML declaration is only valid at the very start of a document, and
    # this SVG is inlined into one.
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

  # Money is whole rupees everywhere in this application, and UPI wants rupees
  # with two decimal places.
  defp amount(nil), do: nil
  defp amount(rupees) when is_integer(rupees) and rupees > 0, do: "#{rupees}.00"
  defp amount(_rupees), do: nil

  # What the payer sees in their UPI app, and what lands on the bank statement.
  defp note(%Invoice{invoice_number: number}) when is_binary(number),
    do: String.slice("Invoice " <> number, 0, 50)

  defp note(_invoice), do: "Invoice"

  # The transaction reference has a restricted character set in practice, so
  # anything else is dropped rather than sent and rejected.
  defp reference(%Invoice{invoice_number: number}) when is_binary(number) do
    number |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(0, 35)
  end

  defp reference(_invoice), do: nil

  # Percent-encode everything outside the unreserved set. `encode_www_form/1`
  # would turn a space into `+`, which several UPI apps show literally in the
  # payee name.
  defp escape(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
