defmodule QuantumBillingWeb.InvoiceNewLive.VATTest do
  @moduledoc "The invoice form for a VAT business: a rate per line, reverse charge, VAT by rate."
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBilling.TaxRates

  setup :register_and_log_in_owner

  setup %{user: user} do
    business = Businesses.default!()

    owner =
      Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))

    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"},
        :tax
      )

    {:ok, _rates} = TaxRates.ensure_presets(owner, "AE")
    %{owner: owner}
  end

  defp rate(name), do: Enum.find(TaxRates.list_rates(archived: :include), &(&1.name == name))

  defp rate_option(index, rate, selected? \\ true) do
    ~s|select[name="invoice[items][#{index}][tax_rate_id]"] option[value="#{rate.id}"]| <>
      if(selected?, do: "[selected]", else: "")
  end

  defp params(items, over \\ %{}) do
    Map.merge(
      %{
        "invoice_type" => "Tax Invoice",
        "invoice_date" => Date.to_iso8601(Date.utc_today()),
        "client_name" => "Gulf Trading LLC",
        "client_tax_number" => "100200300400003",
        "items" => items
      },
      over
    )
  end

  defp item(rate, amount) do
    %{
      "description" => "Consulting",
      "quantity" => "1",
      "unit" => "Nos",
      "rate" => amount,
      "tax_rate_id" => to_string(rate.id)
    }
  end

  test "asks for a VAT rate per line instead of GST and place of supply", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    assert page_title(view) =~ "Create New Invoice"
    assert has_element?(view, rate_option(0, TaxRates.default_rate()))
    assert has_element?(view, "#invoice-reverse-charge")
    assert has_element?(view, ~s|[name="invoice[client_tax_number]"]|)
    assert has_element?(view, "#invoice-summary-vat")

    refute has_element?(view, ~s|[name="invoice[place_of_supply]"]|)
    refute has_element?(view, ~s|[name="invoice[client_gstin]"]|)
    refute has_element?(view, ~s|[name="invoice[items][0][tax_rate]"]|)
    refute has_element?(view, "#invoice-summary-round-off")
  end

  test "a new line starts on the default rate", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    render_change(view, "validate", %{
      "invoice" =>
        params(%{"0" => item(rate("Zero-rated"), "100")}, %{"items_sort" => ["0", "new"]})
    })

    assert has_element?(view, rate_option(0, rate("Zero-rated")))
    assert has_element?(view, rate_option(1, TaxRates.default_rate()))
  end

  test "the summary shows VAT by rate", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    render_change(view, "validate", %{
      "invoice" =>
        params(%{
          "0" => item(rate("Standard 5%"), "1000"),
          "1" => item(rate("Zero-rated"), "500")
        })
    })

    assert has_element?(view, "#invoice-summary-vat-0")
    assert has_element?(view, "#invoice-summary-vat-1")
    assert has_element?(view, "#invoice-summary-vat-total", "50.00")
    assert has_element?(view, "#invoice-summary-grand-total", "1,550.00")
    assert has_element?(view, "#invoice-item-tax-0", "50.00")
    assert has_element?(view, "#invoice-item-tax-1", "0.00")
  end

  test "reverse charge takes the VAT off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    render_change(view, "validate", %{
      "invoice" =>
        params(%{"0" => item(rate("Standard 5%"), "1000")}, %{"reverse_charge" => "true"})
    })

    assert has_element?(view, "#invoice-summary-vat-total", "0.00")
    assert has_element?(view, "#invoice-summary-grand-total", "1,000.00")
    assert has_element?(view, "#invoice-item-tax-0", "0.00")
    assert has_element?(view, "#invoice-summary-vat-note", "Reverse charge")
  end

  test "saves a VAT invoice", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    {:error, {:live_redirect, %{to: "/invoices/" <> id}}} =
      render_submit(view, "save", %{
        "invoice" => params(%{"0" => item(rate("Standard 5%"), "1000")})
      })

    invoice = Invoices.get_invoice!(id)
    assert invoice.tax_regime == "vat"
    assert invoice.vat_amount == 5_000
    assert invoice.client_tax_number == "100200300400003"
    assert [%{tax_rate_bp: 500, tax_name: "Standard 5%"}] = invoice.items
  end

  test "an archived rate stays on the invoices using it, and only there", %{
    conn: conn,
    owner: owner
  } do
    {:ok, hotel} =
      TaxRates.create_rate(owner, %{
        "name" => "Hotel",
        "category" => "reduced",
        "percent" => "7.5"
      })

    {:ok, invoice} =
      Invoices.create_invoice(params(%{"0" => Map.put(item(hotel, "100"), "position", "0")}))

    {:ok, _} = TaxRates.archive_rate(owner, hotel)

    {:ok, edit, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")
    assert has_element?(edit, rate_option(0, hotel))

    {:ok, new, _html} = live(conn, ~p"/invoices/new")
    refute has_element?(new, rate_option(0, hotel, false))
  end
end
