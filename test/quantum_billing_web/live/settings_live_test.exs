defmodule QuantumBillingWeb.SettingsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  # A one-pixel PNG, so an upload test moves real image bytes, with unique
  # trailing bytes per call. Stored files are named by content hash, so two
  # tests uploading identical bytes would share one file — and race each other
  # deleting it on the way out.
  defp png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    ) <> <<System.unique_integer([:positive])::64>>
  end

  describe "page" do
    # The sections live in the app sidebar now, which shows each one's short
    # title — the sidebar already says "Settings" above them.
    test "opens on General with every section in the sidebar", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      assert html =~ "General Settings"

      for section <- QuantumBillingWeb.SettingsComponents.sections() do
        assert has_element?(view, ~s(a[href="/settings/#{section.key}"])),
               "expected a sidebar link for #{section.key}"
      end
    end

    # The open section names the page; there is no standing "Settings" title
    # and no subtitle repeating what the sidebar already says.
    test "the open section titles the page", %{conn: conn} do
      for section <- QuantumBillingWeb.SettingsComponents.sections() do
        {:ok, view, html} = live(conn, ~p"/settings/#{section.key}")

        assert has_element?(view, "h1", section.title)
        refute html =~ "Manage your account and application settings"
      end
    end

    # Save belongs to the page, like every other form screen in the app, and
    # only exists where there is something to save.
    test "Save Changes sits in the page header, not the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      assert has_element?(view, ~s(header button[type="submit"][form="settings-form"]))
    end

    # The sections stay in the DOM so the chevron can animate them open, but
    # nothing opens them on arrival — the chevron is the only control. Account
    # Settings marks the same nav item active, so binding this to the page
    # unfolded the whole list there too.
    test "the sections stay folded on arrival, whatever the page", %{conn: conn} do
      for path <- [~p"/settings", ~p"/settings/tax", ~p"/users/settings", ~p"/invoices"] do
        {:ok, view, _html} = live(conn, path)

        refute has_element?(view, "#settings-sections-toggle[checked]"),
               "expected the settings sections to start folded on #{path}"

        assert has_element?(view, ~s(a[href="/settings/tax"]))
      end
    end

    test "the chevron is the only control that opens them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # A plain label driving the checkbox: no phx-click, so following the
      # Settings link cannot double as opening the list.
      assert has_element?(view, ~s(label[for="settings-sections-toggle"]))
      refute has_element?(view, ~s(a[href="/settings"][phx-click]))
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
            {"customization", "Accent Colour"},
            {"security", "Manage account security"}
          ] do
        {:ok, _view, html} = live(conn, ~p"/settings/#{path}")
        assert html =~ marker, "expected #{path} panel to render #{inspect(marker)}"
      end
    end

    # The sidebar renders on every page, so these links navigate rather than
    # patch — a patch would be invalid from any LiveView other than this one.
    test "clicking the sidebar moves to that section and updates the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      {:ok, _view, html} =
        view
        |> element(~s(a[href="/settings/tax"]))
        |> render_click()
        |> follow_redirect(conn, ~p"/settings/tax")

      assert html =~ "Default GST Rate (%)"
    end

    test "the open section is marked active in the sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      assert has_element?(view, ~s(a[href="/settings/tax"].font-medium))
      refute has_element?(view, ~s(a[href="/settings/invoice"].font-medium))
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

  describe "customization" do
    test "saves the document settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      view
      |> form("#settings-form", %{
        "organization" => %{
          "doc_template" => "Modern",
          "doc_accent_color" => "#1D4ED8",
          "doc_heading" => "TAX INVOICE",
          "doc_footer_text" => "Thank you for your business.",
          "doc_show_hsn" => "false",
          "doc_show_unit" => "false"
        }
      })
      |> render_submit()

      organization = Settings.get_organization()
      assert organization.doc_template == "Modern"
      assert organization.doc_accent_color == "#1D4ED8"
      assert organization.doc_heading == "TAX INVOICE"
      assert organization.doc_footer_text == "Thank you for your business."
      refute organization.doc_show_hsn
      refute organization.doc_show_unit
      # Untouched toggles keep their defaults rather than being cleared.
      assert organization.doc_show_tax_rate
    end

    test "rejects a colour that is not a hex value", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      html =
        view
        |> form("#settings-form", %{"organization" => %{"doc_accent_color" => "red"}})
        |> render_submit()

      assert html =~ "must be a hex colour"
      assert Settings.get_organization().doc_accent_color == "#18181b"
    end

    # The whole point of the upload is a file that survives the request and is
    # then servable, so this asserts on disk rather than on markup.
    test "uploading a logo stores the file and records its path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      logo =
        file_input(view, "#settings-form", :logo, [
          %{
            name: "logo.png",
            content: png(),
            type: "image/png"
          }
        ])

      assert render_upload(logo, "logo.png") =~ "100%"

      view |> form("#settings-form", %{"organization" => %{}}) |> render_submit()

      path = Settings.get_organization().doc_logo_path
      on_exit(fn -> QuantumBilling.Uploads.delete(path) end)

      assert String.starts_with?(path, "/uploads/")
      assert File.exists?(Path.join(QuantumBilling.Uploads.directory(), Path.basename(path)))

      # And it reaches the document, not just the database.
      assert render(view) =~ path
    end

    test "removing a logo clears the setting and unlinks the file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      logo =
        file_input(view, "#settings-form", :logo, [
          %{name: "l.png", content: png(), type: "image/png"}
        ])

      render_upload(logo, "l.png")
      view |> form("#settings-form", %{"organization" => %{}}) |> render_submit()

      path = Settings.get_organization().doc_logo_path
      on_disk = Path.join(QuantumBilling.Uploads.directory(), Path.basename(path))
      assert File.exists?(on_disk)

      view |> element("button[phx-click=remove_logo]") |> render_click()

      assert Settings.get_organization().doc_logo_path == nil
      refute File.exists?(on_disk)
    end

    # The preview is the only feedback before saving, so it has to move with the
    # form rather than with the stored row.
    test "the preview follows the form before anything is saved", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/customization")

      assert html =~ "HSN"

      changed =
        view
        |> form("#settings-form", %{
          "organization" => %{"doc_show_hsn" => "false", "doc_heading" => "PROFORMA"}
        })
        |> render_change()

      assert changed =~ "PROFORMA"
      refute changed =~ ">HSN<"
      # Nothing has been written yet.
      assert Settings.get_organization().doc_show_hsn
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
