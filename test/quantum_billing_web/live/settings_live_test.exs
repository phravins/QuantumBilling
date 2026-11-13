defmodule QuantumBillingWeb.SettingsLiveTest do
  # Not async: concurrent default-template seeders deadlock in the sandbox.
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Layout

  setup :register_and_log_in_owner

  # Unique bytes per call: files are named by content hash, so identical uploads
  # would share one file and race to delete it.
  defp png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    ) <> <<System.unique_integer([:positive])::64>>
  end

  describe "page" do
    test "opens on General with every section in the sidebar", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      # Bare /settings opens the read-only Company Profile.
      assert html =~ "Company Profile"
      assert has_element?(view, "#company-profile")
      refute has_element?(view, "#settings-form")

      for section <- QuantumBillingWeb.SettingsComponents.sections() do
        assert has_element?(view, ~s(a[href="/settings/#{section.key}"])),
               "expected a sidebar link for #{section.key}"
      end
    end

    test "the open section titles the page", %{conn: conn} do
      for section <- QuantumBillingWeb.SettingsComponents.sections() do
        {:ok, view, html} = live(conn, ~p"/settings/#{section.key}")

        assert has_element?(view, "h1", section.title)
        refute html =~ "Manage your account and application settings"
      end
    end

    test "Save Changes sits in the page header, not the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/tax")

      assert has_element?(view, ~s(header button[type="submit"][form="settings-form"]))
    end

    # Each section is a full navigation, so the list renders unfolded.
    test "the sections stay unfolded across the settings panels", %{conn: conn} do
      for path <- [~p"/settings", ~p"/settings/tax", ~p"/settings/customization"] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "#settings-sections-toggle[checked]"),
               "expected the settings sections open on #{path}"
      end
    end

    # Driven off the open section, not the nav item.
    test "and stay folded everywhere else", %{conn: conn} do
      for path <- [~p"/users/settings", ~p"/invoices"] do
        {:ok, view, _html} = live(conn, path)

        refute has_element?(view, "#settings-sections-toggle[checked]"),
               "expected the settings sections folded on #{path}"

        assert has_element?(view, ~s(a[href="/settings/tax"]))
      end
    end

    test "the chevron opens them without a round trip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      # A label driving a checkbox: no phx-click.
      assert has_element?(view, ~s(label[for="settings-sections-toggle"]))
      refute has_element?(view, ~s(a[href="/settings"][phx-click]))
    end

    # Collapsing leaves an icon rail: the buttons are client-side only, and
    # every link keeps a tooltip for when its label is hidden.
    test "the sidebar has its collapse, rail and drawer buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#app-sidebar")
      assert has_element?(view, "#sidebar-collapse")
      assert has_element?(view, "#sidebar-rail-expand")
      assert has_element?(view, "#sidebar-expand")
      assert has_element?(view, ~s(#app-sidebar a[href="/invoices"][title]))
    end

    test "renders the General form fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/general")

      assert html =~ "Company Name"
      assert html =~ "GSTIN"
      assert html =~ "PAN"
      assert html =~ "Financial Year"
      assert html =~ "Logo &amp; Signature"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/settings")
    end

    test "an unknown section falls back to the Company Profile rather than crashing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/nonsense")

      assert has_element?(view, "#company-profile")
    end

    test "the Company Profile is read-only and shows the company's facts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/company")

      assert has_element?(view, "#company-name")
      assert has_element?(view, "#company-facts")
      assert has_element?(view, "#company-member-count")
      assert has_element?(view, "#company-letterhead #company-registration")
      assert has_element?(view, "#company-completeness [role='progressbar']")
      assert has_element?(view, "#company-edit-details[href='/settings/general']")
      assert has_element?(view, "#company-edit-designs[href='/settings/customization']")
      refute has_element?(view, "#settings-form")
    end

    test "staff see the Company Profile too, without the owner's Team link", %{conn: conn} do
      staff = QuantumBilling.AccountsFixtures.user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, staff), ~p"/settings")

      assert has_element?(view, "#company-profile")
      assert has_element?(view, "#company-edit-details")
      refute has_element?(view, "#company-team")
    end

    test "each settings link in the sidebar carries its own icon", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      icons =
        for section <- QuantumBillingWeb.SettingsComponents.sections() do
          assert has_element?(view, "#settings-link-#{section.key} span.#{section.icon}")
          section.icon
        end

      assert icons == Enum.uniq(icons)
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
            {"customization", "Invoice designs"},
            {"security", "Allowed IP Ranges"},
            {"smtp", "SMTP Server Host"},
            {"backup", "1-Click Full System Backup"},
            {"integrations", "Manage webhook endpoints"}
          ] do
        {:ok, _view, html} = live(conn, ~p"/settings/#{path}")
        assert html =~ marker, "expected #{path} panel to render #{inspect(marker)}"
      end
    end

    # Navigate, not patch: the sidebar renders on every LiveView.
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
      {:ok, view, _html} = live(conn, ~p"/settings/general")

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
      {:ok, _view, html} = live(conn, ~p"/settings/general")

      assert html =~ "Acme Traders Private Limited"
      assert html =~ "27AABCA1234A1Z5"
      assert Settings.get_organization().company_name == "Acme Traders Private Limited"
    end

    test "an invalid GSTIN shows an error and does not save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/general")

      html =
        view
        |> form("#settings-form", %{
          "organization" => %{"company_name" => "Acme", "gstin" => "NOPE"}
        })
        |> render_submit()

      assert html =~ "is not a valid GSTIN"
      refute Settings.get_organization().gstin == "NOPE"
    end

    test "a PAN contradicting the GSTIN is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/general")

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
      {:ok, view, _html} = live(conn, ~p"/settings/general")

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

      # LiveViewTest rejects a value the select does not offer; the changeset is
      # covered in QuantumBilling.SettingsTest.
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

  describe "smtp delivery log" do
    test "a delivery can be removed from Recent Deliveries", %{conn: conn} do
      {:ok, delivery} = QuantumBilling.Mail.record_queued(%{to_email: "log@example.com"})

      {:ok, view, _html} = live(conn, ~p"/settings/smtp")
      assert has_element?(view, "#delivery-#{delivery.id}")

      view |> element("#delivery-delete-#{delivery.id}") |> render_click()

      refute has_element?(view, "#delivery-#{delivery.id}")
      assert QuantumBilling.Mail.get_delivery(delivery.id) == nil
    end

    test "a non-owner cannot remove a delivery", %{conn: conn} do
      {:ok, delivery} = QuantumBilling.Mail.record_queued(%{to_email: "keep@example.com"})

      staff = QuantumBilling.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, staff)

      {:ok, view, _html} = live(conn, ~p"/settings/general")
      render_hook(view, "delete_delivery", %{"id" => to_string(delivery.id)})

      assert QuantumBilling.Mail.get_delivery(delivery.id)
    end
  end

  describe "smtp" do
    test "renders and saves custom SMTP configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/smtp")

      view
      |> form("#settings-form", %{
        "organization" => %{
          "smtp_host" => "smtp.sendgrid.net",
          "smtp_port" => "587",
          "smtp_username" => "apikey",
          "smtp_password" => "SG.super-secret",
          "smtp_from_email" => "billing@company.com"
        }
      })
      |> render_submit()

      org = Settings.get_organization()
      assert org.smtp_host == "smtp.sendgrid.net"
      assert org.smtp_port == 587
      assert org.smtp_username == "apikey"
      assert org.smtp_password == "SG.super-secret"
      assert org.smtp_from_email == "billing@company.com"
    end

    test "a username without a password is rejected rather than half-saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/smtp")

      html =
        view
        |> form("#settings-form", %{
          "organization" => %{
            "smtp_host" => "smtp.sendgrid.net",
            "smtp_username" => "apikey",
            "smtp_password" => ""
          }
        })
        |> render_submit()

      assert html =~ "is required when a username is set"
      assert Settings.get_organization().smtp_host == nil
    end

    test "the stored password is never rendered back into the form", %{conn: conn} do
      {:ok, organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"smtp_host" => "smtp.example.com", "smtp_password" => "hunter2-in-the-page"},
          :smtp
        )

      assert organization.smtp_password == "hunter2-in-the-page"

      {:ok, _view, html} = live(conn, ~p"/settings/smtp")

      refute html =~ "hunter2-in-the-page"
    end

    test "saving a panel with a blank password keeps the stored one", %{conn: conn} do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"smtp_host" => "smtp.example.com", "smtp_password" => "keep-me"},
          :smtp
        )

      {:ok, view, _html} = live(conn, ~p"/settings/smtp")

      view
      |> form("#settings-form", %{
        "organization" => %{"smtp_host" => "smtp.example.com", "smtp_password" => ""}
      })
      |> render_submit()

      assert Settings.get_organization().smtp_password == "keep-me"
    end

    test "a stored password satisfies the username rule while editing", %{conn: conn} do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{
            "smtp_host" => "smtp.example.com",
            "smtp_username" => "apikey",
            "smtp_password" => "stored-secret"
          },
          :smtp
        )

      {:ok, view, _html} = live(conn, ~p"/settings/smtp")

      view
      |> form("#settings-form", %{
        "organization" => %{
          "smtp_host" => "smtp.example.org",
          "smtp_username" => "apikey",
          "smtp_password" => ""
        }
      })
      |> render_change()

      refute has_element?(view, "#settings-form", "is required when a username is set")
    end

    test "a failed save does not write the stored password into the page", %{conn: conn} do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"smtp_host" => "smtp.example.com", "smtp_password" => "hunter2-after-error"},
          :smtp
        )

      {:ok, view, _html} = live(conn, ~p"/settings/smtp")

      html =
        view
        |> form("#settings-form", %{
          "organization" => %{"smtp_port" => "0", "smtp_password" => ""}
        })
        |> render_submit()

      assert has_element?(view, "#settings-form", "must be greater than 0")
      # A leak check: the secret must appear nowhere in the markup.
      refute html =~ "hunter2-after-error"
    end

    test "the password field has a show/hide button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/smtp")

      assert has_element?(
               view,
               ~s(#settings-form_smtp_password-reveal[aria-controls="settings-form_smtp_password"])
             )
    end
  end

  describe "backup" do
    test "renders backup download button and restore options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/backup")

      assert html =~ "Export &amp; Download JSON Backup"
      assert html =~ "Restore Database from Backup"
      assert html =~ ~s(href="/settings/backup/download")
    end
  end

  describe "integrations" do
    test "says whether each government portal is in demo or live mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      # Tests configure neither portal.
      assert has_element?(view, ~s(#irp-mode[data-mode="demo"]))
      assert has_element?(view, ~s(#nic-mode[data-mode="demo"]))
    end

    test "renders and updates API & payment integrations", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      view
      |> form("#settings-form", %{
        "organization" => %{
          "razorpay_key_id" => "rzp_test_999"
        }
      })
      |> render_submit()

      org = Settings.get_organization()
      assert org.razorpay_key_id == "rzp_test_999"
    end

    test "secret keys have a show/hide button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      assert has_element?(view, "#settings-form_razorpay_key_secret-reveal")
      assert has_element?(view, "#settings-form_irp_password-reveal")
    end

    test "points to the webhooks page instead of a single URL field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      assert has_element?(view, "#webhooks-settings-link")
      refute has_element?(view, ~s(input[name="organization[webhook_url]"]))
    end

    test "shows the Razorpay webhook URL that names this business", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      slug = QuantumBilling.Businesses.default!().slug

      assert view |> element("#razorpay-webhook-url") |> render() =~
               "/api/webhooks/razorpay/#{slug}"
    end
  end

  defp tools_id(template), do: "text-tools-#{template.id}"

  defp page_of(template) do
    template.id |> Templates.get_template() |> Templates.document_of() |> Map.fetch!(:page)
  end

  # The toolbar is folded away until its card is opened, so every test that
  # drives a control has to open that card first.
  defp open_tools(view, template) do
    view
    |> element(~s(button[phx-click=toggle_text_tools][phx-value-id="#{template.id}"]))
    |> render_click()
  end

  describe "customization" do
    test "seeds a default design and lists it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/customization")

      assert html =~ "Invoice designs"
      assert html =~ "Classic"
      assert html =~ "Default"
      assert Templates.default_template().name == "Classic"
    end

    # Each design's toolbar writes that design's stored layout.
    test "each design has its own text tools", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      first = Templates.default_template()
      {:ok, second} = Templates.duplicate_template(first)

      assert has_element?(
               view,
               ~s(button[phx-click=toggle_text_tools][phx-value-id="#{first.id}"])
             )

      assert has_element?(
               view,
               ~s(button[phx-click=toggle_text_tools][phx-value-id="#{second.id}"])
             )

      open_tools(view, second)

      assert has_element?(view, ~s(##{tools_id(second)}[phx-change="update_page"]))
      refute has_element?(view, "##{tools_id(first)}")
    end

    test "the text tools save typography onto the design they sit in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      template = Templates.default_template()
      open_tools(view, template)

      view
      |> element("##{tools_id(template)}")
      |> render_change(%{
        "template_id" => to_string(template.id),
        "page" => %{
          "font" => "serif",
          "base-font" => "13",
          "line-height" => "relaxed",
          "heading-weight" => "bold",
          "label-case" => "normal",
          "text-color" => "#1d4ed8",
          "margin" => "18mm"
        }
      })

      page = Templates.default_template() |> Templates.document_of() |> Map.fetch!(:page)

      assert page.font == "serif"
      assert page.base_font == 13
      assert page.line_height == "relaxed"
      assert page.heading_weight == "bold"
      assert page.label_case == "normal"
      assert page.text_color == "#1d4ed8"
      assert page.margin == "18mm"
    end

    # Each advanced setting must survive the XML round trip.
    test "the advanced controls save too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      template = Templates.default_template()
      open_tools(view, template)

      view
      |> element("##{tools_id(template)}")
      |> render_change(%{
        "template_id" => to_string(template.id),
        "page" => %{
          "heading-font" => "serif",
          "heading-scale" => "large",
          "heading-color" => "accent",
          "letter-spacing" => "wide",
          "paragraph-spacing" => "relaxed",
          "table-density" => "compact",
          "numerals" => "tabular",
          "label-color" => "#0f766e",
          "muted-color" => "#334155",
          "size" => "Letter"
        }
      })

      page = Templates.default_template() |> Templates.document_of() |> Map.fetch!(:page)

      assert page.heading_font == "serif"
      assert page.heading_scale == "large"
      assert page.heading_color == "accent"
      assert page.letter_spacing == "wide"
      assert page.paragraph_spacing == "relaxed"
      assert page.table_density == "compact"
      assert page.numerals == "tabular"
      assert page.label_color == "#0f766e"
      assert page.muted_color == "#334155"
      assert page.size == "Letter"
    end

    # One card's toolbar must not reach into another card's design.
    test "a design's tools leave the other designs alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      first = Templates.default_template()
      {:ok, second} = Templates.duplicate_template(first)
      open_tools(view, second)

      view
      |> element("##{tools_id(second)}")
      |> render_change(%{"template_id" => to_string(second.id), "page" => %{"font" => "mono"}})

      assert page_of(second).font == "mono"
      assert page_of(first).font == "sans"
    end

    # Colours are interpolated into the stylesheet, so invalid ones are refused.
    test "the text tools refuse a colour that is not one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      template = Templates.default_template()
      open_tools(view, template)

      view
      |> element("##{tools_id(template)}")
      |> render_change(%{
        "template_id" => to_string(template.id),
        "page" => %{
          "text-color" => "red; } body { display: none",
          "label-color" => "url(javascript:alert(1))"
        }
      })

      page = page_of(template)
      assert page.text_color == "#18181b"
      assert page.label_color == "#71717a"
    end

    test "clearing formatting puts the typography back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      template = Templates.default_template()
      open_tools(view, template)

      view
      |> element("##{tools_id(template)}")
      |> render_change(%{
        "template_id" => to_string(template.id),
        "page" => %{"font" => "mono", "heading-weight" => "bold", "numerals" => "tabular"}
      })

      render_click(view, "reset_text", %{"id" => to_string(template.id)})

      page = page_of(template)
      assert page.font == "sans"
      assert page.heading_weight == "semibold"
      assert page.numerals == "proportional"
    end

    test "duplicating adds a copy that is not the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      html =
        view
        |> element("button[phx-click=duplicate_template]")
        |> render_click()

      assert html =~ "Classic copy"
      assert Templates.default_template().name == "Classic"
      assert length(Templates.list_templates()) == 2
    end

    test "a new design opens the starter gallery, and a preset opens the pad", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      refute has_element?(view, "#preset-gallery")
      view |> element("#new-design") |> render_click()
      assert has_element?(view, "#preset-gallery")

      for {key, _name, _description} <- QuantumBillingWeb.InvoiceDoc.Catalog.presets() do
        assert has_element?(view, "#preset-#{key}")
      end

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#preset-modern") |> render_click()

      assert to =~ "/invoice-templates/"
      assert Enum.any?(Templates.list_templates(), &(&1.name == "Modern"))
    end

    test "an unknown preset creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      before = length(Templates.list_templates())

      render_hook(view, "create_from_preset", %{"preset" => "../../etc"})

      assert length(Templates.list_templates()) == before
    end

    test "the gallery closes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      view |> element("#new-design") |> render_click()
      view |> element("#close-gallery") |> render_click()

      refute has_element?(view, "#preset-gallery")
    end

    test "every design has an Export link", %{conn: conn} do
      template = Templates.ensure_default()
      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      assert has_element?(
               view,
               ~s(#export-template-#{template.id}[href="/invoice-templates/#{template.id}/export"])
             )
    end

    test "Import takes a design file and opens the pad", %{conn: conn} do
      xml =
        QuantumBillingWeb.InvoiceDoc.Layout.to_xml(
          QuantumBillingWeb.InvoiceDoc.Catalog.preset("minimal")
        )

      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      view |> element("#import-design") |> render_click()
      assert has_element?(view, "#import-panel")

      file =
        file_input(view, "#import-form", :design_file, [
          %{name: "Our invoice.xml", content: xml, type: "application/xml"}
        ])

      assert {:error, {:live_redirect, %{to: to}}} = render_upload(file, "Our invoice.xml")
      assert to =~ "/invoice-templates/"
      assert Enum.any?(Templates.list_templates(), &(&1.name == "Our invoice"))
    end

    test "Import refuses a file that is not a design", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      view |> element("#import-design") |> render_click()
      before = length(Templates.list_templates())

      file =
        file_input(view, "#import-form", :design_file, [
          %{name: "notes.xml", content: "<html><body>hi</body></html>", type: "application/xml"}
        ])

      render_upload(file, "notes.xml")

      assert has_element?(view, "#import-error")
      assert length(Templates.list_templates()) == before
    end

    test "Import turns a letterhead image into a Letterhead design", %{conn: conn} do
      png =
        <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0,
          0>>

      {:ok, view, _html} = live(conn, ~p"/settings/customization")
      view |> element("#import-design") |> render_click()

      file =
        file_input(view, "#import-form", :letterhead, [
          %{name: "letterhead.png", content: png, type: "image/png"}
        ])

      assert {:error, {:live_redirect, %{to: "/invoice-templates/" <> id}}} =
               render_upload(file, "letterhead.png")

      template = Templates.get_template(String.to_integer(id))
      background = Templates.document_of(template).page.background

      assert template.name == "Letterhead"
      assert QuantumBilling.DesignAssets.owned?(background)
      on_exit(fn -> QuantumBilling.Uploads.delete(background) end)
    end

    test "making another design default swaps which one is", %{conn: conn} do
      original = Templates.ensure_default()
      {:ok, copy} = Templates.duplicate_template(original)

      {:ok, view, _html} = live(conn, ~p"/settings/customization")

      view
      |> element(~s(button[phx-click="set_default_template"][phx-value-id="#{copy.id}"]))
      |> render_click()

      assert Templates.default_template().id == copy.id
    end

    test "a design can be removed, and the default cannot", %{conn: conn} do
      original = Templates.ensure_default()
      {:ok, copy} = Templates.duplicate_template(original)

      {:ok, view, html} = live(conn, ~p"/settings/customization")

      # The default carries no Delete button at all, rather than offering one
      # that errors: removing it would leave new invoices with no design.
      refute html =~ "phx-value-id=\"#{original.id}\" data-confirm"

      view
      |> element(~s(button[phx-click="delete_template"][phx-value-id="#{copy.id}"]))
      |> render_click()

      assert Enum.map(Templates.list_templates(), & &1.id) == [original.id]
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

    # Each card is a real render of the design, not a name in a list, so a
    # change made in the pad is visible here without opening it.
    test "the list shows each design as it will print", %{conn: conn} do
      template = Templates.ensure_default()

      document =
        template
        |> Templates.document_of()
        |> Map.update!(:blocks, &Enum.reject(&1, fn b -> b.type == :amount_in_words end))

      {:ok, _template} =
        Templates.update_template(template, %{"layout_xml" => Layout.to_xml(document)})

      {:ok, _view, html} = live(conn, ~p"/settings/customization")

      assert html =~ "qb-doc__items"
      refute html =~ "Amount in Words"
    end
  end

  describe "security" do
    test "renders security policies and account settings link", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/settings/security")

      assert html =~ user.email
      assert html =~ ~s(href="/users/settings")
      assert html =~ "Allowed IP Ranges"

      view
      |> form("#settings-form", %{
        "organization" => %{
          "allowed_ips" => "192.168.1.0/24",
          "session_timeout_minutes" => "30",
          "audit_retention_days" => "90"
        }
      })
      |> render_submit()

      # The sign-in rules are the installation's; the retention is this business's.
      rules = QuantumBilling.InstallationSettings.get()
      assert rules.allowed_ips == "192.168.1.0/24"
      assert rules.session_timeout_minutes == 30
      assert Settings.get_organization().audit_retention_days == 90
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
