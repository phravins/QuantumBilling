defmodule QuantumBillingWeb.InvoiceDoc.Extras do
  @moduledoc """
  Data a layout needs beyond the invoice, gathered before rendering:

    * `:payment` - `%{upi_id, payee, qr, bank}`, or `nil` without a payment block
    * `:images` - `%{path => src}` for the background and image blocks

  Only paths `DesignAssets.owned?/1` accepts are rendered. With `inline: true`
  (PDF, print, public page) images become `data:` URIs.
  """

  alias QuantumBilling.DesignAssets
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.QRCode
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoicePdfGenerator

  @empty %{payment: nil, images: %{}}

  @doc "Extras for a page with none of the newer blocks."
  def empty, do: @empty

  @doc """
  Builds the extras for rendering `invoice` with `document`.

  Options: `:inline` (default `false`), `:organization` (if already loaded).
  """
  def build(%Invoice{} = invoice, %Document{} = document, opts \\ []) do
    paths = Layout.asset_paths(document)
    payment? = Document.has_type?(document, :payment)

    if paths == [] and not payment? do
      @empty
    else
      organization = Keyword.get_lazy(opts, :organization, &Settings.get_organization/0)

      %{
        payment: if(payment?, do: payment(invoice, organization)),
        images: images(paths, Keyword.get(opts, :inline, false))
      }
    end
  end

  @doc """
  The payment details for `invoice` from the organisation. Public for the design pad preview.
  """
  def payment(%Invoice{} = invoice, %Organization{} = organization) do
    %{
      upi_id: presence(organization.upi_vpa),
      payee:
        presence(organization.upi_payee_name) || presence(organization.trade_name) ||
          presence(organization.company_name),
      qr: QRCode.generate_invoice_upi_qr(invoice, organization: organization, width: 160),
      bank: bank_lines(organization)
    }
  end

  def payment(_invoice, _organization), do: nil

  defp bank_lines(%Organization{} = organization) do
    [
      {"Account name", organization.bank_account_name},
      {"Bank", organization.bank_name},
      {"Account no.", organization.bank_account_number},
      {"IFSC", organization.bank_ifsc},
      {"Branch", organization.bank_branch}
    ]
    |> Enum.reject(fn {_label, value} -> presence(value) == nil end)
  end

  defp images(paths, inline?) do
    paths
    |> Enum.filter(&DesignAssets.owned?/1)
    |> Map.new(fn path ->
      {path, if(inline?, do: InvoicePdfGenerator.inline_logo(path), else: path)}
    end)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
