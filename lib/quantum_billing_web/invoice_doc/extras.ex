defmodule QuantumBillingWeb.InvoiceDoc.Extras do
  @moduledoc """
  Data a layout needs beyond the invoice, gathered before rendering:

    * `:payment` - `%{upi_id, payee, qr, bank}`, or `nil` without a payment block
    * `:images` - `%{path => src}` for the background and image blocks
    * `:custom` - `%{invoice: defs, items: defs}`, the custom fields marked
      "Show on invoice" for the custom-fields block and extra item columns
    * `:zatca` - `%{svg: qr}`, the Saudi e-invoice QR code, or `nil` when the
      invoice is not under ZATCA (see `QuantumBilling.Zatca`)

  Only paths `DesignAssets.owned?/1` accepts are rendered. With `inline: true`
  (PDF, print, public page) images become `data:` URIs.
  """

  alias QuantumBilling.CustomFields
  alias QuantumBilling.DesignAssets
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.QRCode
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Zatca
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoicePdfGenerator

  @no_custom %{invoice: [], items: []}
  @empty %{payment: nil, images: %{}, custom: @no_custom, zatca: nil}

  @doc "Extras for a page with none of the newer blocks."
  def empty, do: @empty

  @doc """
  Builds the extras for rendering `invoice` with `document`.

  Options: `:inline` (default `false`), `:organization` (if already loaded).
  """
  def build(%Invoice{} = invoice, %Document{} = document, opts \\ []) do
    paths = Layout.asset_paths(document)
    payment? = Document.has_type?(document, :payment)
    custom = custom(invoice, document)
    zatca = zatca(invoice, document)

    if paths == [] and not payment? do
      %{@empty | custom: custom, zatca: zatca}
    else
      organization = Keyword.get_lazy(opts, :organization, &Settings.get_organization/0)

      %{
        payment: if(payment?, do: payment(invoice, organization)),
        images: images(paths, Keyword.get(opts, :inline, false)),
        custom: custom,
        zatca: zatca
      }
    end
  end

  @doc """
  The Saudi e-invoice QR code, as inline SVG so the offline PDF renderer
  draws it too. `nil` unless the invoice is under ZATCA and the layout has
  the QR block (`ZatcaLayout.adapt/2` adds it).
  """
  def zatca(%Invoice{} = invoice, %Document{} = document) do
    with true <- Zatca.applies?(invoice) and Document.has_type?(document, :zatca_qr),
         svg when svg != "" <- QRCode.generate_svg(Zatca.qr_payload(invoice), width: 160) do
      %{svg: svg}
    else
      _no_qr -> nil
    end
  end

  @doc """
  The printable custom fields for `invoice`. Archived fields are included so
  an issued invoice keeps printing its values. Nothing is read unless the
  layout has a custom-fields block or an item holds a value.

  A quotation rendered as a document (`invoice_type` "Quotation") prints the
  quotation's own fields.
  """
  def custom(%Invoice{} = invoice, %Document{} = document) do
    items = if is_list(invoice.items), do: invoice.items, else: []
    {object, item_object} = custom_objects(invoice)

    %{
      invoice: if(Document.has_type?(document, :custom_fields), do: printable(object), else: []),
      items:
        if(Enum.any?(items, &(&1.custom_fields not in [nil, %{}])),
          do: printable(item_object),
          else: []
        )
    }
  end

  defp custom_objects(%Invoice{invoice_type: "Quotation"}), do: {"quotation", "quotation_item"}
  defp custom_objects(%Invoice{}), do: {"invoice", "invoice_item"}

  defp printable(object) do
    object
    |> CustomFields.list_definitions(archived: :include)
    |> Enum.filter(& &1.show_on_invoice)
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
