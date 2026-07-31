defmodule QuantumBillingWeb.SettingsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  describe "page" do
    test "opens on General with every section in the nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Manage your account and application settings"
      assert html =~ "General Settings"
      assert html =~ "Invoice Settings"
      assert html =~ "E-Way Bill Settings"
      assert html =~ "Tax Settings"
      assert html =~ "Users &amp; Roles"
      assert html =~ "Notifications"
      assert html =~ "Backup &amp; Restore"
      assert html =~ "Integrations"
      assert html =~ "Security"
      assert html =~ "Preferences"
    end

    test "renders the General form fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Company Name"
      assert html =~ "GSTIN"
      assert html =~ "PAN"
      assert html =~ "Financial Year"
      assert html =~ "Logo &amp; Signature"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/settings")
    end

    test "an unknown section falls back to General rather than crashing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/nonsense")

      assert html =~ "Company Name"
    end
  end

  describe "section navigation" do
    test "each section is reachable by URL", %{conn: conn} do
      for {path, marker} <- [
            {"invoice", "Invoice Prefix"},
            {"e_way_bill", "Default Transport Mode"},
            {"tax", "Default GST Rate (%)"},
            {"notifications", "Remind me this many days ahead"},
            {"preferences", "Rows Per Page"},
            {"security", "Manage account security"}
          ] do
        {:ok, _view, html} = live(conn, ~p"/settings/#{path}")
        assert html =~ marker, "expected #{path} panel to render #{inspect(marker)}"
      end
    end

    test "clicking the nav moves to that section and updates the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> element(~s(a[href="/settings/tax"])) |> render_click()

      assert html =~ "Default GST Rate (%)"
      assert_patched(view, ~p"/settings/tax")
    end
  end

  describe "saving" do
    test "General persists and survives a remount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form", %{
        "organization" => %{
          "company_name" => "Acme Traders Private Limited",
          "gstin" => "27AABCA1234A1Z5",
          "pan" => "AABCA1234A",
          "state" => "Maharashtra (27)"
        }
      })
      |> render_submit()

      # The whole point of the migration: mount again and the values come back.
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Acme Traders Private Limited"
      assert html =~ "27AABCA1234A1Z5"
      assert Settings.get_organization().company_name == "Acme Traders Private Limited"
    end

    test "an invalid GSTIN shows an error and does not save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#settings-form", %{
          "organization" => %{"company_name" => "Acme", "gstin" => "NOPE"}
        })
        |> render_submit()

      assert html =~ "is not a valid GSTIN"
      assert Settings.get_organization().id == nil
    end

    test "a PAN contradicting the GSTIN is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#settings-form", %{
          "organization" => %{
            "company_name" => "Acme",
            "gstin" => "27AABCA1234A1Z5",
            "pan" => "ZZZZZ9999Z"
          }
        })
        |> render_submit()

      assert html =~ "does not match the PAN in the GSTIN"
    end

    test "sections save independently of each other", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#settings-form", %{"organization" => %{"company_name" => "Acme"}})
      |> render_submit()

      # Tax saves without General's required company name being resubmitted.
      {:ok, tax_view, _html} = live(conn, ~p"/settings/tax")

      tax_view
      |> form("#settings-form", %{"organization" => %{"default_gst_rate" => "12"}})
      |> render_submit()

      organization = Settings.get_organization()
      assert organization.company_name == "Acme"
      assert organization.default_gst_rate == 12
    end

    test "toggles can be switched off, not just on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      # Default is true; the hidden false input is what makes unchecking work.
      view
      |> form("#settings-form", %{"organization" => %{"notify_invoice_created" => "false"}})
      |> render_submit()

      assert Settings.get_organization().notify_invoice_created == false
    end

    test "the invoice panel previews the next number as you type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/invoice")

      html =
        view
        |> form("#settings-form", %{
          "organization" => %{
            "invoice_prefix" => "GST",
            "invoice_next_number" => "42",
            "invoice_number_padding" => "5"
          }
        })
        |> render_change()

      assert html =~ "GST-00042"
    end

    test "the rate select offers only the statutory slabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      # The control cannot produce an invalid rate in the first place —
      # LiveViewTest rejects a value the select does not offer. The changeset
      # remains the backstop for non-form callers and is covered in
      # QuantumBilling.SettingsTest.
      assert_raise ArgumentError, ~r/must be one of \["0", "5", "12", "18", "28"\]/, fn ->
        view
        |> form("#settings-form", %{"organization" => %{"default_gst_rate" => "7"}})
        |> render_change()
      end

      view
      |> form("#settings-form", %{"organization" => %{"default_gst_rate" => "28"}})
      |> render_submit()

      assert Settings.get_organization().default_gst_rate == 28
    end
  end

  describe "sections that are not built" do
    test "say so rather than offering dead controls", %{conn: conn} do
      for {path, needs} <- [
            {"users", "roles model"},
            {"backup", "backup tooling"},
            {"integrations", "credentials"}
          ] do
        {:ok, _view, html} = live(conn, ~p"/settings/#{path}")

        assert html =~ "is not available yet"
        assert html =~ needs
        refute html =~ "Save Changes"
      end
    end
  end

  describe "security" do
    test "links to the account page instead of duplicating it", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/settings/security")

      assert html =~ user.email
      assert html =~ ~s(href="/users/settings")
      refute html =~ "Save Changes"
    end
  end

  describe "preferences" do
    test "offers the theme toggle, which needs no database", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/preferences")

      assert html =~ "phx-theme"
      assert html =~ "Rows Per Page"
    end
  end
end
