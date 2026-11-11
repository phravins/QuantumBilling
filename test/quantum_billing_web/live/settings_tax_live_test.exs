defmodule QuantumBillingWeb.SettingsLive.TaxTest do
  @moduledoc "Settings › Tax: the GST/VAT switch and the owner-only VAT rates."
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Audit
  alias QuantumBilling.Settings
  alias QuantumBilling.TaxRates

  @uae %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"}

  defp switch_to_vat(view) do
    view
    |> form("#settings-form", %{"organization" => %{"tax_regime" => "vat"}})
    |> render_change()

    view |> form("#settings-form", %{"organization" => @uae}) |> render_submit()
  end

  defp rate_named(name),
    do: Enum.find(TaxRates.list_rates(archived: :include), &(&1.name == name))

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "a GST business sees the GST fields and no rates", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      assert has_element?(view, "#settings-form_default_gst_rate")
      refute has_element?(view, "#vat-identity")
      refute has_element?(view, "#tax-rates-card")
    end

    test "switching to VAT shows the VAT fields before saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      view
      |> form("#settings-form", %{"organization" => %{"tax_regime" => "vat"}})
      |> render_change()

      assert has_element?(view, "#vat-identity")
      refute has_element?(view, "#settings-form_default_gst_rate")
    end

    test "a save elsewhere does not wipe unsaved edits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      view
      |> form("#settings-form", %{"organization" => %{"tax_regime" => "vat"}})
      |> render_change()

      send(view.pid, {:settings_updated, Settings.get_organization()})

      assert has_element?(view, "#vat-identity")
    end

    test "VAT needs a country and a valid number", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      view
      |> form("#settings-form", %{"organization" => %{"tax_regime" => "vat"}})
      |> render_change()

      view
      |> form("#settings-form", %{
        "organization" => %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "12"}
      })
      |> render_submit()

      assert Settings.get_organization().tax_regime == "gst"
      assert TaxRates.list_rates() == []
    end

    test "saving VAT adds the country's preset rates once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")
      switch_to_vat(view)

      organization = Settings.get_organization()
      assert organization.tax_regime == "vat"
      assert organization.vat_country == "AE"

      rates = TaxRates.list_rates()
      assert Enum.map(rates, & &1.rate_bp) == [500, 0, 0, 0]
      assert TaxRates.default_rate().name == "Standard 5%"
      assert has_element?(view, "#tax-rates-card")

      for rate <- rates, do: assert(has_element?(view, "#tax_rates-#{rate.id}"))

      # A second save leaves the owner's rates alone.
      view |> form("#settings-form", %{"organization" => @uae}) |> render_submit()
      assert length(TaxRates.list_rates()) == 4
    end

    test "adds, edits, defaults, archives and restores a rate", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")
      switch_to_vat(view)

      view |> element("#new-rate") |> render_click()
      assert has_element?(view, "#rate-dialog")
      assert has_element?(view, "#tax_rate_percent")

      view
      |> form("#rate-form", %{"tax_rate" => %{"name" => "Hotel", "category" => "reduced"}})
      |> render_change()

      view
      |> form("#rate-form", %{
        "tax_rate" => %{"name" => "Hotel", "category" => "reduced", "percent" => "7.5"}
      })
      |> render_submit()

      refute has_element?(view, "#rate-dialog")
      hotel = rate_named("Hotel")
      assert hotel.rate_bp == 750

      view |> element("#edit-rate-#{hotel.id}") |> render_click()

      view
      |> form("#rate-form", %{"tax_rate" => %{"percent" => "8"}})
      |> render_submit()

      assert rate_named("Hotel").rate_bp == 800

      view |> element("#default-rate-#{hotel.id}") |> render_click()
      assert TaxRates.default_rate().id == hotel.id

      view |> element("#archive-rate-#{hotel.id}") |> render_click()
      assert rate_named("Hotel").archived_at
      refute TaxRates.default_rate().id == hotel.id
      assert has_element?(view, "#restore-rate-#{hotel.id}")

      view |> element("#restore-rate-#{hotel.id}") |> render_click()
      refute rate_named("Hotel").archived_at
      refute has_element?(view, "#archived-rates")

      actions = Enum.map(Audit.list_audit_logs(), & &1.action)

      for action <-
            ~w(tax_rates_preset_added tax_rate_created tax_rate_updated tax_rate_default_set
               tax_rate_archived tax_rate_restored) do
        assert action in actions
      end
    end

    test "an untaxed rate is saved at 0% with its reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")
      switch_to_vat(view)
      view |> element("#new-rate") |> render_click()

      view
      |> form("#rate-form", %{"tax_rate" => %{"name" => "Healthcare", "category" => "exempt"}})
      |> render_change()

      refute has_element?(view, "#tax_rate_percent")

      view
      |> form("#rate-form", %{
        "tax_rate" => %{
          "name" => "Healthcare",
          "category" => "exempt",
          "exemption_reason" => "Exempt supply"
        }
      })
      |> render_submit()

      assert %{rate_bp: 0, exemption_reason: "Exempt supply"} = rate_named("Healthcare")
    end

    test "an invalid rate keeps the dialog open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")
      switch_to_vat(view)
      view |> element("#new-rate") |> render_click()

      view
      |> form("#rate-form", %{
        "tax_rate" => %{"name" => "Odd", "category" => "standard", "percent" => "150"}
      })
      |> render_submit()

      assert has_element?(view, "#rate-dialog")
      refute rate_named("Odd")
    end
  end

  describe "as staff" do
    setup :register_and_log_in_owner

    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")
      switch_to_vat(view)

      staff = QuantumBilling.AccountsFixtures.user_fixture()
      %{conn: log_in_user(conn, staff)}
    end

    test "see the regime and rates but cannot change them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      assert has_element?(view, "#tax-regime-summary")
      refute has_element?(view, "#settings-form_tax_regime")
      refute has_element?(view, "#vat-identity")
      assert has_element?(view, "#tax-rates-card")
      refute has_element?(view, "#new-rate")
      refute has_element?(view, "[id^='edit-rate-']")
    end

    test "a forged save cannot switch the regime back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      render_submit(view, "save", %{"organization" => %{"tax_regime" => "gst"}})
      assert Settings.get_organization().tax_regime == "vat"
    end

    test "forged rate events are refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")
      rate = TaxRates.default_rate()

      render_click(view, "new_rate", %{})
      refute has_element?(view, "#rate-dialog")

      assert render_click(view, "archive_rate", %{"id" => rate.id}) =~
               "limited to account owners"

      refute rate_named(rate.name).archived_at
    end
  end
end
