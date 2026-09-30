defmodule QuantumBillingWeb.BinLiveTest do
  @moduledoc """
  The Bin page: what has been deleted, and the two things that can be done
  with it.

  Rows are addressed by id — `#bin-invoice-<id>`, `#bin-recurring-<id>`,
  `#bin-template-<id>` — and never by searching the page for a name. The bell in
  the layout lists a notification for every invoice created, naming its number
  and its client, so text on the page says nothing about what the table holds.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Recurring
  alias QuantumBilling.Repo
  alias QuantumBilling.Templates
  alias QuantumBilling.Templates.InvoiceTemplate
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  setup :register_and_log_in_user

  defp client_fixture do
    {:ok, client} =
      Clients.create_client(%{
        "client_type" => "Unregistered",
        "name" => "Acme Traders",
        "phone" => "9876543210",
        "billing_line1" => "1 Main Street",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400001"
      })

    client
  end

  defp invoice_fixture(over \\ %{}) do
    {:ok, invoice} =
      Invoices.create_invoice(
        Map.merge(
          %{
            "invoice_date" => "2026-03-01",
            "place_of_supply" => "Maharashtra (27)",
            "client_name" => "V2V Technologies",
            "items" => %{
              "0" => %{
                "description" => "Web Development Services",
                "quantity" => "1",
                "unit" => "Nos",
                "rate" => "50000",
                "tax_rate" => "18",
                "position" => "0"
              }
            }
          },
          over
        )
      )

    invoice
  end

  defp binned_invoice(over \\ %{}) do
    {:ok, invoice} = over |> invoice_fixture() |> Invoices.delete_invoice()
    invoice
  end

  defp binned_profile(title \\ "Monthly retainer") do
    {:ok, profile} =
      Recurring.create_profile(%{
        "client_id" => client_fixture().id,
        "title" => title,
        "frequency" => "Monthly",
        "next_run_date" => Date.to_iso8601(Date.utc_today())
      })

    {:ok, profile} = Recurring.delete_profile(profile)
    profile
  end

  defp template_fixture(name) do
    {:ok, template} =
      Templates.create_template(%{
        "name" => name,
        "layout_xml" => Layout.to_xml(Catalog.classic())
      })

    template
  end

  defp binned_template(name \\ "Letterhead") do
    {:ok, template} = name |> template_fixture() |> Templates.delete_template()
    template
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/bin")
  end

  test "sits in the sidebar, immediately before Settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bin")

    assert has_element?(view, ~s|nav a[href="/bin"]|, "Bin")
    assert has_element?(view, ~s|nav li:has(a[href="/bin"]) + li a[href="/settings"]|)
    refute has_element?(view, ~s|nav li:has(a[href="/settings"]) + li a[href="/bin"]|)
  end

  describe "an empty Bin" do
    test "says so rather than drawing an empty table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, "#bin-empty", "The Bin is empty")
      assert has_element?(view, "#bin-count-all", "0")
      refute has_element?(view, "#bin-entries tr")
    end

    test "does not list what has not been deleted", %{conn: conn} do
      invoice = invoice_fixture()
      template = template_fixture("Live design")

      {:ok, view, _html} = live(conn, ~p"/bin")

      refute has_element?(view, "#bin-invoice-#{invoice.id}")
      refute has_element?(view, "#bin-template-#{template.id}")
      assert has_element?(view, "#bin-empty")
    end
  end

  describe "with deleted records" do
    test "lists each kind with the two actions", %{conn: conn} do
      invoice = binned_invoice()
      profile = binned_profile("Northwind retainer")
      template = binned_template("Letterhead")

      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, "#bin-invoice-#{invoice.id}", invoice.invoice_number)
      assert has_element?(view, "#bin-invoice-#{invoice.id}", "V2V Technologies")
      assert has_element?(view, "#bin-recurring-#{profile.id}", "Northwind retainer")
      assert has_element?(view, "#bin-recurring-#{profile.id}", "Acme Traders")
      assert has_element?(view, "#bin-template-#{template.id}", "Letterhead")

      for row <- ["invoice-#{invoice.id}", "recurring-#{profile.id}", "template-#{template.id}"] do
        assert has_element?(view, "#bin-restore-#{row}")
        assert has_element?(view, "#bin-purge-#{row}[data-confirm]")
      end

      refute has_element?(view, "#bin-empty")
    end

    test "counts each kind on its chip", %{conn: conn} do
      binned_invoice()
      binned_invoice()
      binned_profile()

      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, "#bin-count-all", "3")
      assert has_element?(view, "#bin-count-invoice", "2")
      assert has_element?(view, "#bin-count-recurring", "1")
      assert has_element?(view, "#bin-count-template", "0")
    end

    test "a chip narrows the list to its kind", %{conn: conn} do
      invoice = binned_invoice()
      profile = binned_profile()

      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, ~s|#bin-filter-all[aria-pressed="true"]|)

      view |> element("#bin-filter-recurring") |> render_click()

      assert has_element?(view, ~s|#bin-filter-recurring[aria-pressed="true"]|)
      assert has_element?(view, ~s|#bin-filter-all[aria-pressed="false"]|)
      assert has_element?(view, "#bin-recurring-#{profile.id}")
      refute has_element?(view, "#bin-invoice-#{invoice.id}")

      # The chips go on counting everything: they say what is in the Bin, not
      # what the filter left.
      assert has_element?(view, "#bin-count-invoice", "1")

      view |> element("#bin-filter-all") |> render_click()

      assert has_element?(view, "#bin-invoice-#{invoice.id}")
      assert has_element?(view, "#bin-recurring-#{profile.id}")
    end

    test "a chip with nothing behind it shows its own empty state", %{conn: conn} do
      invoice = binned_invoice()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-filter-template") |> render_click()

      assert has_element?(view, "#bin-empty", "Nothing of this kind in the Bin")
      refute has_element?(view, "#bin-invoice-#{invoice.id}")
    end

    test "a filter the page does not offer is ignored", %{conn: conn} do
      invoice = binned_invoice()

      {:ok, view, _html} = live(conn, ~p"/bin")

      render_click(view, "filter", %{"type" => "everything"})

      assert has_element?(view, ~s|#bin-filter-all[aria-pressed="true"]|)
      assert has_element?(view, "#bin-invoice-#{invoice.id}")
    end
  end

  describe "restore" do
    test "puts an invoice back on the invoice list", %{conn: conn, user: user} do
      invoice = binned_invoice()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-invoice-#{invoice.id}") |> render_click()

      refute has_element?(view, "#bin-invoice-#{invoice.id}")
      assert has_element?(view, "#bin-empty")
      assert has_element?(view, "#flash-info", "restored")

      assert Invoices.get_invoice(invoice.id)

      {:ok, list, _html} = live(conn, ~p"/invoices")
      assert has_element?(list, "#invoice-#{invoice.id}")

      assert Enum.any?(Audit.list_audit_logs(), fn log ->
               log.action == "restore_invoice" and log.user_id == user.id and
                 log.resource_id == to_string(invoice.id)
             end)
    end

    test "puts a recurring profile back on its schedule", %{conn: conn} do
      profile = binned_profile()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-recurring-#{profile.id}") |> render_click()

      refute has_element?(view, "#bin-recurring-#{profile.id}")
      assert Enum.map(Recurring.due_profiles(), & &1.id) == [profile.id]
    end

    test "puts a design back among the designs", %{conn: conn} do
      template = binned_template("Letterhead")

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-template-#{template.id}") |> render_click()

      refute has_element?(view, "#bin-template-#{template.id}")
      assert Enum.map(Templates.list_templates(), & &1.name) == ["Letterhead"]
    end

    test "says what a design is called now when its name was taken", %{conn: conn} do
      template = binned_template("Letterhead")
      template_fixture("Letterhead")

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-template-#{template.id}") |> render_click()

      assert has_element?(view, "#flash-info", "Letterhead (restored)")
    end
  end

  describe "delete permanently" do
    test "removes an invoice for good", %{conn: conn, user: user} do
      invoice = binned_invoice()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-purge-invoice-#{invoice.id}") |> render_click()

      refute has_element?(view, "#bin-invoice-#{invoice.id}")
      assert has_element?(view, "#flash-info", "permanently deleted")
      refute Repo.get(Invoice, invoice.id)

      assert Enum.any?(Audit.list_audit_logs(), fn log ->
               log.action == "purge_invoice" and log.user_id == user.id
             end)
    end

    test "removes a recurring profile for good", %{conn: conn} do
      profile = binned_profile()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-purge-recurring-#{profile.id}") |> render_click()

      refute has_element?(view, "#bin-recurring-#{profile.id}")
      assert Recurring.list_deleted_profiles() == []
    end

    test "removes a design nothing was issued with", %{conn: conn} do
      template = binned_template()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-purge-template-#{template.id}") |> render_click()

      refute has_element?(view, "#bin-template-#{template.id}")
      refute Repo.get(InvoiceTemplate, template.id)
    end

    # The row is the record of which design those invoices carry, so there is
    # no button to press — and the event is refused if it is sent anyway.
    test "is not offered for a design invoices were issued with", %{conn: conn} do
      template = template_fixture("Issued")
      invoice_fixture() |> Ecto.Changeset.change(template_id: template.id) |> Repo.update!()
      {:ok, template} = Templates.delete_template(template)

      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, "#bin-locked-template-#{template.id}")
      assert has_element?(view, "#bin-restore-template-#{template.id}")
      refute has_element?(view, "#bin-purge-template-#{template.id}")

      render_click(view, "purge", %{"type" => "template", "id" => to_string(template.id)})

      assert has_element?(view, "#flash-error", "cannot be permanently deleted")
      assert Repo.get(InvoiceTemplate, template.id)
    end
  end

  describe "an action on something that is no longer there" do
    test "reports it rather than crashing", %{conn: conn} do
      invoice = binned_invoice()

      {:ok, view, _html} = live(conn, ~p"/bin")

      # Restored from another window while this one was open.
      {:ok, _invoice} = Invoices.restore_invoice(invoice)

      render_click(view, "restore", %{"type" => "invoice", "id" => to_string(invoice.id)})

      assert has_element?(view, "#flash-error", "no longer in the Bin")
    end

    test "an invoice that is not in the Bin cannot be purged through the page", %{conn: conn} do
      invoice = invoice_fixture()

      {:ok, view, _html} = live(conn, ~p"/bin")

      render_click(view, "purge", %{"type" => "invoice", "id" => to_string(invoice.id)})

      assert has_element?(view, "#flash-error", "no longer in the Bin")
      assert Repo.get(Invoice, invoice.id)
    end

    test "an unknown type or id is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bin")

      render_click(view, "purge", %{"type" => "client", "id" => "1"})
      assert has_element?(view, "#flash-error", "no longer in the Bin")

      render_click(view, "restore", %{"type" => "invoice", "id" => "not-an-id"})
      assert has_element?(view, "#flash-error", "no longer in the Bin")
    end
  end

  describe "while the page is open" do
    test "an invoice deleted elsewhere arrives without a reload", %{conn: conn} do
      invoice = invoice_fixture()

      {:ok, view, _html} = live(conn, ~p"/bin")
      assert has_element?(view, "#bin-empty")

      {:ok, _invoice} = Invoices.delete_invoice(invoice)

      # `render/1` is a call into the view, so it is answered after the
      # broadcast ahead of it in the mailbox has been handled.
      render(view)

      assert has_element?(view, "#bin-invoice-#{invoice.id}")
      assert has_element?(view, "#bin-count-all", "1")
      refute has_element?(view, "#bin-empty")
    end
  end
end
