defmodule QuantumBilling.Zatca do
  @moduledoc """
  Saudi Arabia's e-invoicing rules, Phase 1 ("generation"), in force since
  4 December 2021.

  An invoice falls under them when it was issued on the VAT regime by a
  business whose VAT country is Saudi Arabia, in Saudi riyals. Such an invoice
  (or credit or debit note):

    * is titled in English and Arabic: "Tax Invoice" when the buyer has a VAT
      number, "Simplified Tax Invoice" when not;
    * carries a QR code holding, as Base64 of a TLV, the seller's name, the
      seller's VAT number, the time of issue, the total with VAT and the VAT.

  Everything here is a pure function of the invoice's own snapshot, so the
  QR code of an issued invoice never changes when Settings do.

  Phase 2 (UBL XML, the cryptographic stamp, clearance and reporting) is not
  implemented.
  """

  alias QuantumBilling.Compliance
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Money
  alias QuantumBilling.Zatca.TLV

  @country "SA"
  @currency "SAR"
  @timezone "Asia/Riyadh"

  @titles %{
    {"Tax Invoice", :standard} => {"Tax Invoice", "فاتورة ضريبية"},
    {"Tax Invoice", :simplified} => {"Simplified Tax Invoice", "فاتورة ضريبية مبسطة"},
    {"Credit Note", :standard} => {"Credit Note", "إشعار دائن"},
    {"Credit Note", :simplified} => {"Simplified Credit Note", "إشعار دائن مبسط"},
    {"Debit Note", :standard} => {"Debit Note", "إشعار مدين"},
    {"Debit Note", :simplified} => {"Simplified Debit Note", "إشعار مدين مبسط"}
  }

  @doc """
  Whether `invoice` must follow ZATCA Phase 1: issued on VAT by a Saudi
  business, in SAR. Quotations never do.
  """
  def applies?(%Invoice{invoice_type: "Quotation"}), do: false

  def applies?(%Invoice{} = invoice) do
    invoice.tax_regime == "vat" and invoice.company_vat_country == @country and
      invoice.currency == @currency
  end

  def applies?(_other), do: false

  @doc "Whether `invoice` is a simplified (B2C) one: the buyer has no VAT number."
  def simplified?(%Invoice{client_tax_number: number}),
    do: String.trim(number || "") == ""

  @doc """
  The document's title as `{english, arabic}`.

  Credit and debit notes keep their kind; every other type is a tax invoice,
  since Saudi VAT has no bill of supply and an export is a zero-rated tax
  invoice.
  """
  def title(%Invoice{} = invoice) do
    kind = if invoice.invoice_type in ["Credit Note", "Debit Note"], do: invoice.invoice_type

    Map.fetch!(
      @titles,
      {kind || "Tax Invoice", if(simplified?(invoice), do: :simplified, else: :standard)}
    )
  end

  @doc """
  The time of issue for the QR code, in UTC as `YYYY-MM-DDTHH:MM:SSZ`.

  The day is the invoice date, the time of day is when the invoice was
  created, both as the clock read in Riyadh. Using the creation time keeps the
  QR code the same on every copy.
  """
  def timestamp(%Invoice{} = invoice) do
    offset = Compliance.utc_offset(@timezone)
    created = created_at(invoice)
    local = Compliance.local_time(created, @timezone)
    date = invoice.invoice_date || NaiveDateTime.to_date(local)

    date
    |> NaiveDateTime.new!(NaiveDateTime.to_time(local))
    |> NaiveDateTime.add(-offset, :second)
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
    |> Kernel.<>("Z")
  end

  # An unsaved invoice (a design preview) has no creation time; midnight in
  # Riyadh keeps its QR code steady between renders.
  defp created_at(%Invoice{inserted_at: %DateTime{} = at}), do: at

  defp created_at(%Invoice{inserted_at: %NaiveDateTime{} = at}),
    do: DateTime.from_naive!(at, "Etc/UTC")

  defp created_at(%Invoice{invoice_date: %Date{} = date}) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-Compliance.utc_offset(@timezone), :second)
  end

  defp created_at(_invoice), do: DateTime.utc_now(:second)

  @doc """
  The five Phase 1 QR fields, as `[{tag, value}]`:

    1. the seller's name, in Arabic when the business gave one;
    2. the seller's VAT registration number;
    3. the time of issue (`timestamp/1`);
    4. the invoice total with VAT;
    5. the VAT total.
  """
  def qr_tags(%Invoice{} = invoice) do
    [
      {1, seller_name(invoice)},
      {2, invoice.company_tax_number || ""},
      {3, timestamp(invoice)},
      {4, Money.to_input(invoice.grand_total || 0, @currency)},
      {5, Money.to_input(invoice.vat_amount || 0, @currency)}
    ]
  end

  @doc "The QR code's content: Base64 of the TLV of `qr_tags/1`."
  def qr_payload(%Invoice{} = invoice) do
    invoice |> qr_tags() |> TLV.encode() |> Base.encode64()
  end

  defp seller_name(%Invoice{} = invoice) do
    case String.trim(invoice.company_name_ar || "") do
      "" -> invoice.company_name || ""
      arabic -> arabic
    end
  end
end
