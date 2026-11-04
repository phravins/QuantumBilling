defmodule QuantumBillingWeb.InvoiceDoc.Extras do
  @moduledoc """
  What a layout's newer blocks need beyond the invoice itself: the payment
  details and the uploaded images.

  The renderer is a pure function of its assigns, so anything read from the
  organisation or from disk is gathered here first and handed in as one map:

    * `:payment` — `%{upi_id, payee, qr, bank}`, where `qr` is an inline SVG
      (or `""`) and `bank` is a list of `{label, value}` lines. `nil` when the
      layout has no payment block, so pages without one pay nothing for it.
    * `:images` — `%{path => src}` for the page background and image blocks.

  ## Only this business's files

  A path in a layout is only rendered when `DesignAssets.owned?/1` agrees it
  belongs to the current business — the same rule the upload controller
  applies. A layout cannot be made to inline another business's letterhead by
  naming its file.

  With `inline: true` (the PDF, the print page, the public pay page) each image
  is read into a `data:` URI, because those are read where `/uploads/…` means
  nothing or where the visitor has no session to fetch it with.
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

  ## Options

    * `:inline` — inline images as data URIs (default `false`).
    * `:organization` — the organisation, when the caller already has it.
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
  The payment details for `invoice`, read from the organisation.

  Public so the design pad can show the block with real values beside a sample
  invoice.
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
