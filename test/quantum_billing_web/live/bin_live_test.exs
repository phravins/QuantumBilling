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
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
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

  defp registered_client_fixture(name \\ "Northwind Traders") do
    {:ok, client} =
      Clients.create_client(%{
        "client_type" => "Registered Business",
        "name" => name,
        "gstin" => "27AABCA1234A1Z5",
        "email" => "accounts@northwind.test",
        "phone" => "9876543210",
        "billing_line1" => "123 Business Park",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400093"
      })

    client
  end

  defp binned_client(name \\ "Northwind Traders") do
    {:ok, client} = name |> registered_client_fixture() |> Clients.delete_client()
    client
  end

  # Inserted rather than built through the invoice form: an e-way bill needs an
  # issued invoice with a consignee state, which a draft does not have.
  defp consignment_fixture do
    Repo.insert!(%Invoice{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_state: "Karnataka",
      client_name: "Contoso Logistics",
      taxable_value: 100_000,
      grand_total: 118_000
    })
  end

  defp bill_fixture(invoice \\ nil) do
    {:ok, bill} =
      EWayBills.generate_e_way_bill(invoice || consignment_fixture(), %{
        "distance_km" => "180",
        "vehicle_number" => "MH04CD5678"
      })

    bill
  end

  defp binned_bill(invoice \\ nil) do
    {:ok, bill} = invoice |> bill_fixture() |> EWayBills.delete_e_way_bill()
    bill
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

      render_click(view, "purge", %{"type" => "credit_note", "id" => "1"})
      assert has_element?(view, "#flash-error", "no longer in the Bin")

      render_click(view, "restore", %{"type" => "invoice", "id" => "not-an-id"})
      assert has_element?(view, "#flash-error", "no longer in the Bin")
    end
  end

  describe "clients in the Bin" do
    test "are listed with the two actions and counted on their own chip", %{conn: conn} do
      client = binned_client()
      invoice = binned_invoice()

      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, "#bin-client-#{client.id}", "Northwind Traders")
      assert has_element?(view, "#bin-client-#{client.id}", "27AABCA1234A1Z5")
      assert has_element?(view, "#bin-restore-client-#{client.id}")
      assert has_element?(view, "#bin-purge-client-#{client.id}[data-confirm]")

      assert has_element?(view, "#bin-count-all", "2")
      assert has_element?(view, "#bin-count-client", "1")

      view |> element("#bin-filter-client") |> render_click()

      assert has_element?(view, ~s|#bin-filter-client[aria-pressed="true"]|)
      assert has_element?(view, "#bin-client-#{client.id}")
      refute has_element?(view, "#bin-invoice-#{invoice.id}")
    end

    test "restore puts the client back on the client list", %{conn: conn, user: user} do
      client = binned_client()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-client-#{client.id}") |> render_click()

      refute has_element?(view, "#bin-client-#{client.id}")
      assert has_element?(view, "#bin-empty")
      assert has_element?(view, "#flash-info", "restored")

      {:ok, list, _html} = live(conn, ~p"/clients")
      assert has_element?(list, "#client-#{client.id}")

      assert Enum.any?(Audit.list_audit_logs(), fn log ->
               log.action == "restore_client" and log.user_id == user.id and
                 log.resource_id == to_string(client.id)
             end)
    end

    # Two live clients cannot share a GSTIN. The page says why rather than
    # quietly doing nothing.
    test "restore is refused when the GSTIN now belongs to another client", %{conn: conn} do
      client = binned_client()
      registered_client_fixture("Northwind Traders (new)")

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-client-#{client.id}") |> render_click()

      assert has_element?(view, "#flash-error", "cannot be restored")
      assert has_element?(view, "#bin-client-#{client.id}")
      assert Clients.get_client(client.id) == nil
    end

    test "delete permanently removes the client for good", %{conn: conn, user: user} do
      client = binned_client()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-purge-client-#{client.id}") |> render_click()

      refute has_element?(view, "#bin-client-#{client.id}")
      assert has_element?(view, "#flash-info", "permanently deleted")
      refute Repo.get(Client, client.id)

      assert Enum.any?(Audit.list_audit_logs(), fn log ->
               log.action == "purge_client" and log.user_id == user.id
             end)
    end

    # A credit note is a tax document raised against the client, so there is
    # no button to press — and the event is refused if it is sent anyway.
    test "delete permanently is not offered for a client with credit notes", %{conn: conn} do
      client = registered_client_fixture()

      invoice =
        Repo.insert!(%Invoice{
          invoice_number: "INV-#{System.unique_integer([:positive])}",
          invoice_date: Date.utc_today(),
          place_of_supply: "Maharashtra (27)",
          company_state: "Maharashtra (27)",
          client_id: client.id,
          client_name: client.name,
          client_gstin: client.gstin,
          taxable_value: 100_000,
          grand_total: 118_000,
          status: "E-Invoice Generated"
        })

      {:ok, _note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "reason" => "Returned",
          "grand_total" => Decimal.new("18000.00")
        })

      {:ok, client} = Clients.delete_client(client)

      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, "#bin-locked-client-#{client.id}")
      assert has_element?(view, "#bin-restore-client-#{client.id}")
      refute has_element?(view, "#bin-purge-client-#{client.id}")

      render_click(view, "purge", %{"type" => "client", "id" => to_string(client.id)})

      assert has_element?(view, "#flash-error", "cannot be permanently deleted")
      assert Repo.get(Client, client.id)
    end

    test "a client that is not in the Bin cannot be purged through the page", %{conn: conn} do
      client = registered_client_fixture()

      {:ok, view, _html} = live(conn, ~p"/bin")

      render_click(view, "purge", %{"type" => "client", "id" => to_string(client.id)})

      assert has_element?(view, "#flash-error", "no longer in the Bin")
      assert Repo.get(Client, client.id)
    end
  end

  describe "e-way bills in the Bin" do
    test "are listed with the two actions and counted on their own chip", %{conn: conn} do
      bill = binned_bill()
      invoice = binned_invoice()

      {:ok, view, _html} = live(conn, ~p"/bin")

      assert has_element?(view, "#bin-e_way_bill-#{bill.id}", bill.ewb_number)
      assert has_element?(view, "#bin-e_way_bill-#{bill.id}", "Contoso Logistics")
      assert has_element?(view, "#bin-restore-e_way_bill-#{bill.id}")
      assert has_element?(view, "#bin-purge-e_way_bill-#{bill.id}[data-confirm]")

      assert has_element?(view, "#bin-count-all", "2")
      assert has_element?(view, "#bin-count-e_way_bill", "1")

      view |> element("#bin-filter-e_way_bill") |> render_click()

      assert has_element?(view, ~s|#bin-filter-e_way_bill[aria-pressed="true"]|)
      assert has_element?(view, "#bin-e_way_bill-#{bill.id}")
      refute has_element?(view, "#bin-invoice-#{invoice.id}")
    end

    test "restore puts the bill back on the e-way bill list", %{conn: conn, user: user} do
      bill = binned_bill()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-e_way_bill-#{bill.id}") |> render_click()

      refute has_element?(view, "#bin-e_way_bill-#{bill.id}")
      assert has_element?(view, "#flash-info", "restored")

      {:ok, list, _html} = live(conn, ~p"/e-way-bills")
      assert has_element?(list, "#ewb-#{bill.ewb_number}")

      assert Enum.any?(Audit.list_audit_logs(), fn log ->
               log.action == "restore_e_way_bill" and log.user_id == user.id and
                 log.resource_id == to_string(bill.id)
             end)
    end

    # An invoice carries one live bill, and the one raised since is the one in
    # use.
    test "restore is refused when its invoice has another bill now", %{conn: conn} do
      invoice = consignment_fixture()
      bill = binned_bill(invoice)
      bill_fixture(invoice)

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-restore-e_way_bill-#{bill.id}") |> render_click()

      assert has_element?(view, "#flash-error", "cannot be restored")
      assert has_element?(view, "#bin-e_way_bill-#{bill.id}")
      assert EWayBills.get_e_way_bill(bill.id) == nil
    end

    test "delete permanently removes the bill for good", %{conn: conn, user: user} do
      bill = binned_bill()

      {:ok, view, _html} = live(conn, ~p"/bin")

      view |> element("#bin-purge-e_way_bill-#{bill.id}") |> render_click()

      refute has_element?(view, "#bin-e_way_bill-#{bill.id}")
      assert has_element?(view, "#flash-info", "permanently deleted")
      refute Repo.get(EWayBill, bill.id)
      assert Repo.get(Invoice, bill.invoice_id)

      assert Enum.any?(Audit.list_audit_logs(), fn log ->
               log.action == "purge_e_way_bill" and log.user_id == user.id
             end)
    end

    test "a bill that is not in the Bin cannot be purged through the page", %{conn: conn} do
      bill = bill_fixture()

      {:ok, view, _html} = live(conn, ~p"/bin")

      render_click(view, "purge", %{"type" => "e_way_bill", "id" => to_string(bill.id)})

      assert has_element?(view, "#flash-error", "no longer in the Bin")
      assert Repo.get(EWayBill, bill.id)
    end
  end

  describe "while the page is open" do
    test "a client deleted elsewhere arrives without a reload", %{conn: conn} do
      client = registered_client_fixture()

      {:ok, view, _html} = live(conn, ~p"/bin")
      assert has_element?(view, "#bin-empty")

      {:ok, _client} = Clients.delete_client(client)
      render(view)

      assert has_element?(view, "#bin-client-#{client.id}")
      assert has_element?(view, "#bin-count-client", "1")
    end

    # A client that was only added or edited is none of the Bin's business,
    # but the topic carries it, so the page has to take the message.
    test "a client added or edited elsewhere leaves the page as it was", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bin")

      client = registered_client_fixture()
      {:ok, _client} = Clients.update_client(client, %{"name" => "Northwind Traders Pvt Ltd"})
      render(view)

      assert has_element?(view, "#bin-empty")
      assert has_element?(view, "#bin-count-all", "0")
    end

    test "an e-way bill deleted elsewhere arrives without a reload", %{conn: conn} do
      bill = bill_fixture()

      {:ok, view, _html} = live(conn, ~p"/bin")
      assert has_element?(view, "#bin-empty")

      {:ok, _bill} = EWayBills.delete_e_way_bill(bill)
      render(view)

      assert has_element?(view, "#bin-e_way_bill-#{bill.id}")
      assert has_element?(view, "#bin-count-e_way_bill", "1")
    end

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
