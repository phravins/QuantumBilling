defmodule QuantumBillingWeb.InvoiceDocumentVATTest do
  @moduledoc """
  A VAT invoice on screen and in print: the VAT number in place of the GSTIN,
  VAT by rate in place of CGST/SGST/IGST, and the reverse-charge legend.
  """
  # Not async: concurrent default-template seeders deadlock (see InvoiceDocumentTest).
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBilling.TaxRates
  alias QuantumBillingWeb.InvoiceDocument

  @trn "100123456700003"
  @client_trn "100200300400003"

  setup :register_and_log_in_owner

  setup %{user: user} do
    business = Businesses.default!()

    owner =
      Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))

    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => @trn},
        :tax
      )

    {:ok, _rates} = TaxRates.ensure_presets(owner, "AE")
    :ok
  end

  defp rate(name), do: Enum.find(TaxRates.list_rates(), &(&1.name == name)).id

  defp invoice!(lines, attrs \\ %{}) do
    items =
      lines
      |> Enum.with_index()
      |> Map.new(fn {{rate_name, amount, hsn}, index} ->
        {to_string(index),
         %{
           "description" => "Line #{index}",
           "hsn_sac" => hsn,
           "quantity" => "1",
           "unit" => "Nos",
           "rate" => amount,
           "tax_rate_id" => to_string(rate(rate_name))
         }}
      end)

    {:ok, invoice} =
      %{
        "invoice_date" => Date.to_iso8601(~D[2026-11-02]),
        "client_name" => "Gulf Trading LLC",
        "client_tax_number" => @client_trn,
        "items" => items
      }
      |> Map.merge(attrs)
      |> Invoices.create_invoice()

    invoice
  end

  defp both(conn, invoice) do
    {:ok, _view, screen} = live(conn, ~p"/invoices/#{invoice.id}")
    printed = conn |> get(~p"/invoices/#{invoice.id}/pdf") |> html_response(200)
    [{"screen", screen}, {"printed", printed}]
  end

  defp document(html) do
    html |> LazyHTML.from_document() |> LazyHTML.query(".qb-doc")
  end

  defp texts(html, selector) do
    html
    |> document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  test "prints VAT numbers, VAT by rate and no GST", %{conn: conn} do
    invoice = invoice!([{"Standard 5%", "1000", ""}, {"Zero-rated", "500", ""}])

    for {label, html} <- both(conn, invoice) do
      doc = html |> document() |> LazyHTML.text()

      assert doc =~ "VAT No. / TRN: #{@trn}", label
      assert doc =~ "VAT No. / TRN: #{@client_trn}", label
      refute doc =~ "GSTIN", label
      refute doc =~ "CGST", label
      refute doc =~ "IGST", label
      refute doc =~ "Place of Supply", label

      lines = texts(html, ".qb-doc__total-line")
      assert Enum.any?(lines, &(&1 =~ ~r/^VAT 5% .*50\.00$/)), label
      assert Enum.any?(lines, &(&1 =~ ~r/^Grand Total .*1,550\.00$/)), label
      refute Enum.any?(lines, &(&1 =~ "Round Off")), label

      # No item codes were entered, so the HSN column is gone; the rate prints per line.
      headers = texts(html, ".qb-doc__items:not(.qb-doc__vat-summary) thead th")
      refute "HSN / SAC" in headers, label
      refute "Item Code" in headers, label
      assert "VAT" in headers, label

      rows = texts(html, ".qb-doc__items:not(.qb-doc__vat-summary) tbody tr")
      assert Enum.any?(rows, &(&1 =~ " 5% ")), label
      assert Enum.any?(rows, &(&1 =~ " 0% ")), label

      assert [standard, zero] = texts(html, ".qb-doc__vat-summary tbody tr"), label
      assert standard =~ "Standard 5%"
      assert standard =~ "1,000.00"
      assert zero =~ "Zero-rated"
    end
  end

  test "one rate needs no VAT summary; an item code keeps the column", %{conn: conn} do
    invoice = invoice!([{"Standard 5%", "1000", "SKU-7"}])

    for {label, html} <- both(conn, invoice) do
      assert texts(html, ".qb-doc__vat-summary") == [], label
      assert "Item Code" in texts(html, ".qb-doc__items thead th"), label
      assert html |> document() |> LazyHTML.text() =~ "SKU-7", label
    end
  end

  test "reverse charge prints no VAT and the legend", %{conn: conn} do
    invoice = invoice!([{"Standard 5%", "1000", ""}], %{"reverse_charge" => "true"})

    for {label, html} <- both(conn, invoice) do
      lines = texts(html, ".qb-doc__total-line")
      assert Enum.any?(lines, &(&1 =~ ~r/^VAT \(reverse charge\) .*0\.00$/)), label
      assert Enum.any?(lines, &(&1 =~ ~r/^Grand Total .*1,000\.00$/)), label
      assert [legend] = texts(html, ".qb-doc__legend"), label
      assert legend =~ "customer is to account for the VAT"
    end
  end

  test "an exempt-only invoice still prints its VAT, at zero", %{conn: conn} do
    invoice = invoice!([{"Exempt", "800", ""}])

    for {label, html} <- both(conn, invoice) do
      lines = texts(html, ".qb-doc__total-line")
      assert Enum.any?(lines, &(&1 =~ ~r/^VAT .*0\.00$/)), label
      rows = texts(html, ".qb-doc__items tbody tr")
      assert Enum.any?(rows, &(&1 =~ "Exempt")), label
    end
  end

  test "the design pad previews a VAT invoice" do
    sample = InvoiceDocument.pad_sample(Settings.get_organization())

    assert sample.tax_regime == "vat"
    assert sample.vat_amount == 90_000
    assert sample.grand_total == 2_490_000
    assert [%{"rate_bp" => 500}, %{"rate_bp" => 0}] = sample.tax_breakdown
    assert is_nil(sample.place_of_supply)

    assert InvoiceDocument.sample(Settings.get_organization()).company_tax_number == @trn
  end
end
