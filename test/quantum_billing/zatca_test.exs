defmodule QuantumBilling.ZatcaTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Zatca
  alias QuantumBilling.Zatca.TLV

  # ZATCA's own worked example (E-Invoicing Detailed Guideline): Bobs Records,
  # 25 April 2022 15:30 UTC, 1,000.00 with 150.00 VAT.
  @zatca_example "AQxCb2JzIFJlY29yZHMCDzMxMDEyMjM5MzUwMDAwMwMUMjAyMi0wNC0yNVQxNTozMDowMFoEBzEwMDAuMDAFBjE1MC4wMA=="

  defp saudi(attrs \\ %{}) do
    struct(
      %Invoice{
        invoice_type: "Tax Invoice",
        tax_regime: "vat",
        company_vat_country: "SA",
        currency: "SAR",
        company_name: "Bobs Records",
        company_tax_number: "310122393500003",
        invoice_date: ~D[2022-04-25],
        inserted_at: ~U[2022-04-25 15:30:00Z],
        grand_total: 100_000,
        vat_amount: 15_000
      },
      attrs
    )
  end

  describe "applies?/1" do
    test "a Saudi VAT invoice in SAR" do
      assert Zatca.applies?(saudi())
    end

    test "not a GST invoice, another VAT country, another currency or a quotation" do
      refute Zatca.applies?(saudi(%{tax_regime: "gst"}))
      refute Zatca.applies?(saudi(%{company_vat_country: "AE"}))
      refute Zatca.applies?(saudi(%{company_vat_country: nil}))
      refute Zatca.applies?(saudi(%{currency: "USD"}))
      refute Zatca.applies?(saudi(%{invoice_type: "Quotation"}))
      refute Zatca.applies?(nil)
    end
  end

  test "simplified?/1 is a buyer without a VAT number" do
    assert Zatca.simplified?(saudi())
    assert Zatca.simplified?(saudi(%{client_tax_number: "   "}))
    refute Zatca.simplified?(saudi(%{client_tax_number: "300000000000003"}))
  end

  test "title/1 for invoices and notes, standard and simplified" do
    buyer = %{client_tax_number: "300000000000003"}

    assert Zatca.title(saudi(buyer)) == {"Tax Invoice", "فاتورة ضريبية"}
    assert Zatca.title(saudi()) == {"Simplified Tax Invoice", "فاتورة ضريبية مبسطة"}

    assert Zatca.title(saudi(Map.put(buyer, :invoice_type, "Credit Note"))) ==
             {"Credit Note", "إشعار دائن"}

    assert Zatca.title(saudi(%{invoice_type: "Credit Note"})) ==
             {"Simplified Credit Note", "إشعار دائن مبسط"}

    assert Zatca.title(saudi(Map.put(buyer, :invoice_type, "Debit Note"))) ==
             {"Debit Note", "إشعار مدين"}

    assert Zatca.title(saudi(%{invoice_type: "Debit Note"})) ==
             {"Simplified Debit Note", "إشعار مدين مبسط"}

    # Saudi VAT has no bill of supply; an export is a zero-rated tax invoice.
    assert Zatca.title(saudi(%{invoice_type: "Export Invoice"})) ==
             {"Simplified Tax Invoice", "فاتورة ضريبية مبسطة"}
  end

  describe "timestamp/1" do
    test "the invoice date at the creation time of day in Riyadh, in UTC" do
      # 01:30 on 27 November in Riyadh; dated the 27th, so no day shift.
      invoice = saudi(%{invoice_date: ~D[2026-11-27], inserted_at: ~U[2026-11-26 22:30:00Z]})

      assert Zatca.timestamp(invoice) == "2026-11-26T22:30:00Z"
    end

    test "an invoice dated another day keeps that day" do
      invoice = saudi(%{invoice_date: ~D[2026-11-20], inserted_at: ~U[2026-11-27 09:15:42Z]})

      assert Zatca.timestamp(invoice) == "2026-11-20T09:15:42Z"
    end

    test "a naive creation time is read as UTC" do
      invoice = saudi(%{inserted_at: ~N[2022-04-25 15:30:00]})

      assert Zatca.timestamp(invoice) == "2022-04-25T15:30:00Z"
    end

    test "an unsaved invoice is stamped midnight in Riyadh, the same on every render" do
      invoice = saudi(%{inserted_at: nil, invoice_date: ~D[2026-11-27]})

      assert Zatca.timestamp(invoice) == "2026-11-26T21:00:00Z"
      assert Zatca.timestamp(invoice) == Zatca.timestamp(invoice)
    end
  end

  describe "qr_payload/1" do
    test "matches ZATCA's worked example" do
      assert Zatca.qr_payload(saudi()) == @zatca_example
    end

    test "carries the Arabic seller name when there is one" do
      invoice = saudi(%{company_name_ar: "شركة ماثل التجريبية"})

      assert {:ok, tags} = invoice |> Zatca.qr_payload() |> Base.decode64!() |> TLV.decode()

      assert tags == [
               {1, "شركة ماثل التجريبية"},
               {2, "310122393500003"},
               {3, "2022-04-25T15:30:00Z"},
               {4, "1000.00"},
               {5, "150.00"}
             ]
    end

    test "a blank Arabic name falls back to the English" do
      invoice = saudi(%{company_name_ar: "  "})

      assert [{1, "Bobs Records"} | _rest] = Zatca.qr_tags(invoice)
    end
  end
end
