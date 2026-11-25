defmodule QuantumBilling.ActivityCoverageTest do
  @moduledoc """
  One test per area of the books: each change a member makes lands in the
  audit log once, against that member, with a name a person can read.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.ApiFixtures, only: [client_fixture: 1]

  alias QuantumBilling.AccountsFixtures
  alias QuantumBilling.Audit
  alias QuantumBilling.Backup
  alias QuantumBilling.Clients
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Recurring
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  defp entries(action), do: Enum.filter(Audit.list_audit_logs(), &(&1.action == action))

  defp acting_member(_context) do
    user = AccountsFixtures.user_fixture()
    Audit.put_actor(%{user_id: user.id, ip_address: "203.0.113.20", name: "Asha Rao"})
    on_exit(fn -> Audit.clear_actor() end)
    %{member: user}
  end

  defp assert_one(action, member) do
    assert [log] = entries(action)
    assert log.user_id == member.id
    assert log.ip_address == "203.0.113.20"
    assert log.details["actor"] == "Asha Rao"
    log
  end

  defp issued_invoice(client) do
    Repo.insert!(%Invoice{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: Date.utc_today(),
      place_of_supply: "Maharashtra (27)",
      company_state: "Maharashtra (27)",
      client_id: client.id,
      client_name: client.name,
      taxable_value: 100_000,
      grand_total: 118_000,
      status: "E-Invoice Generated"
    })
  end

  defp new_template(name) do
    {:ok, template} =
      Templates.create_template(%{
        "name" => name,
        "layout_xml" => Layout.to_xml(Catalog.classic())
      })

    template
  end

  describe "a member's changes" do
    setup :acting_member

    test "clients: created and edited", %{member: member} do
      client = client_fixture(%{"name" => "Delta Exports"})
      assert assert_one("client_created", member).details["label"] == "Delta Exports"

      {:ok, _client} = Clients.update_client(client, %{"email" => "pay@delta.example"})
      log = assert_one("client_updated", member)
      assert %{"to" => "pay@delta.example"} = log.details["changes"]["email"]
    end

    test "invoices: created and edited", %{member: member} do
      client = client_fixture(%{"name" => "Epsilon Labs"})

      {:ok, invoice} =
        Invoices.create_invoice(%{
          "client_id" => client.id,
          "client_name" => client.name,
          "invoice_date" => "2026-03-01",
          "place_of_supply" => "Maharashtra (27)",
          "items" => %{
            "0" => %{
              "description" => "Consulting",
              "hsn_sac" => "998313",
              "quantity" => "2",
              "unit" => "Hrs",
              "rate" => "5000",
              "tax_rate" => "18"
            }
          }
        })

      created = assert_one("invoice_created", member)
      assert created.resource_id == to_string(invoice.id)
      assert created.details["label"] == invoice.invoice_number

      {:ok, _invoice} = Invoices.update_invoice(invoice, %{"remarks" => "Net 30"})
      updated = assert_one("invoice_updated", member)
      assert %{"to" => "Net 30"} = updated.details["changes"]["remarks"]
    end

    test "credit notes", %{member: member} do
      invoice = issued_invoice(client_fixture(%{"name" => "Zeta Foods"}))

      {:ok, note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "reason" => "Returned",
          "grand_total" => Decimal.new("180.00")
        })

      log = assert_one("credit_note_created", member)
      assert log.details["label"] == note.note_number
      assert log.details["invoice_number"] == invoice.invoice_number
    end

    test "recurring profiles: created, paused and edited", %{member: member} do
      client = client_fixture(%{"name" => "Eta Studio"})

      {:ok, profile} =
        Recurring.create_profile(%{
          title: "Hosting",
          frequency: "Monthly",
          next_run_date: Date.utc_today(),
          client_id: client.id,
          auto_send_email: false
        })

      assert assert_one("recurring_profile_created", member).details["label"] == "Hosting"

      {:ok, profile} = Recurring.update_profile(profile, %{status: "Paused"})
      assert_one("recurring_profile_paused", member)

      {:ok, _profile} = Recurring.update_profile(profile, %{title: "Hosting (annual)"})
      log = assert_one("recurring_profile_updated", member)
      assert log.details["changes"]["title"] == %{"from" => "Hosting", "to" => "Hosting (annual)"}
    end

    test "templates: created, copied and made the default", %{member: member} do
      template = new_template("Ledger")
      assert assert_one("invoice_template_created", member).details["label"] == "Ledger"

      {:ok, copy} = Templates.duplicate_template(template)
      assert assert_one("invoice_template_duplicated", member).details["label"] == copy.name

      {:ok, _default} = Templates.set_default(template)
      assert assert_one("invoice_template_set_default", member).details["label"] == "Ledger"
    end

    test "settings", %{member: member} do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"invoice_terms" => "Payment within 30 days.", "invoice_due_days" => "30"},
          :invoice
        )

      log = assert_one("settings_updated", member)
      assert log.details["label"] == "Invoice settings"
      assert %{"to" => "Payment within 30 days."} = log.details["changes"]["invoice_terms"]
    end

    test "a backup restore is recorded after the restore, so it is kept", %{member: member} do
      json = Backup.export_json()

      assert {:ok, _counts} = Backup.restore_json(json)

      assert assert_one("backup_restored", member).resource_type == "Backup"
    end
  end

  describe "the owner's pages" do
    setup :register_and_log_in_owner

    test "a backup download names who took the data", %{conn: conn, user: owner} do
      conn = get(conn, ~p"/settings/backup/download")
      assert conn.status == 200

      assert [log] = entries("backup_downloaded")
      assert log.user_id == owner.id
      assert log.ip_address == "127.0.0.1"
    end

    test "inviting a member", %{conn: conn, user: owner} do
      {:ok, view, _html} = live(conn, ~p"/settings/team")

      view
      |> form("#invite-form", %{
        "invitation" => %{"email" => "new.member@example.com", "role" => "staff"}
      })
      |> render_submit()

      assert [log] = entries("member_invited")
      assert log.user_id == owner.id
      assert log.details["label"] == "new.member@example.com"
    end
  end
end
