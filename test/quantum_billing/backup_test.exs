defmodule QuantumBilling.BackupTest do
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Backup
  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates

  defp client_fixture(attrs \\ %{}) do
    {:ok, client} =
      Clients.create_client(
        Map.merge(
          %{
            client_type: "Registered Business",
            name: "Acme Corp",
            gstin: "27AAACA1234A1Z5",
            phone: "9876543210",
            email: "billing@acme.test",
            billing_line1: "Main St",
            billing_city: "Mumbai",
            billing_state: "Maharashtra (27)",
            billing_pin: "400001"
          },
          attrs
        )
      )

    client
  end

  defp invoice_fixture(client) do
    {:ok, invoice} =
      Invoices.create_invoice(%{
        "client_id" => client.id,
        "client_name" => client.name,
        "client_gstin" => client.gstin,
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

    invoice
  end

  describe "export_json/0" do
    test "produces JSON rather than raising on Ecto structs" do
      client = client_fixture()
      invoice_fixture(client)

      # The previous exporter handed structs to Jason, which raises on
      # `__meta__` — so the download button returned a 500 every time.
      json = Backup.export_json()
      data = Jason.decode!(json)

      assert data["version"] == "2.0"
      assert [%{"name" => "Acme Corp"}] = data["clients"]
      assert [%{"invoice_number" => number}] = data["invoices"]
      assert is_binary(number)
      assert [%{"description" => "Consulting"}] = data["invoice_items"]
    end

    test "leaves stored credentials out of the file" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"smtp_host" => "smtp.example.com", "smtp_password" => "hunter2-in-the-backup"},
          :smtp
        )

      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"webhook_url" => "https://example.test/h", "webhook_secret" => "whsec_in_the_backup"},
          :integrations
        )

      json = Backup.export_json()

      # A backup is a file people email to each other; live credentials do not
      # belong in one, and these decrypt on read.
      refute json =~ "hunter2-in-the-backup"
      refute json =~ "whsec_in_the_backup"
      refute json =~ "smtp_password"

      # Configuration that is not a credential still travels.
      assert json =~ "https://example.test/h"
    end

    test "counts what is in a backup" do
      client = client_fixture()
      invoice_fixture(client)

      counts = Backup.summarize(Jason.decode!(Backup.export_json()))

      assert counts["clients"] == 1
      assert counts["invoices"] == 1
      assert counts["invoice_items"] == 1
    end
  end

  describe "restore_json/1" do
    test "brings back everything it deletes" do
      client = client_fixture()
      invoice = invoice_fixture(client)
      Templates.ensure_default()

      json = Backup.export_json()

      # Wipe the lot, as a fresh machine would be.
      Repo.delete_all(QuantumBilling.Invoices.InvoiceItem)
      Repo.delete_all(Invoice)
      Repo.delete_all(QuantumBilling.Clients.Client)

      assert Invoices.list_invoices() == []

      assert {:ok, counts} = Backup.restore_json(json)

      assert counts.clients == 1
      assert counts.invoices == 1
      assert counts.invoice_items == 1

      # The previous restore deleted invoices and re-inserted only clients, so
      # restoring a backup destroyed the invoices it was meant to bring back.
      [restored] = Invoices.list_invoices()
      assert restored.number == invoice.invoice_number

      restored = Invoices.get_invoice(restored.id)
      assert [item] = restored.items
      assert item.description == "Consulting"
      assert restored.grand_total == invoice.grand_total
      assert restored.client_id
    end

    test "restores settings without clobbering credentials that are not in the file" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name" => "Acme Exports", "gstin" => "27AAACA1234A1Z5"},
          :general
        )

      json = Backup.export_json()

      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name" => "Something Else"},
          :general
        )

      assert {:ok, _counts} = Backup.restore_json(json)
      assert Settings.get_organization().company_name == "Acme Exports"
    end

    test "a later insert does not collide with restored ids" do
      client = client_fixture()
      invoice_fixture(client)
      json = Backup.export_json()

      Repo.delete_all(QuantumBilling.Invoices.InvoiceItem)
      Repo.delete_all(Invoice)
      Repo.delete_all(QuantumBilling.Clients.Client)

      assert {:ok, _counts} = Backup.restore_json(json)

      # Rows keep their original ids, so the sequences have to be moved past
      # them or the next insert fails on the primary key.
      assert %{id: id} = client_fixture(%{name: "Globex", gstin: "27AAACN1234C1ZP"})
      assert is_integer(id)
    end

    test "refuses a file that is not a backup, changing nothing" do
      client = client_fixture()
      invoice_fixture(client)

      assert {:error, message} = Backup.restore_json("{}")
      assert message =~ "not a QuantumBilling backup"

      assert {:error, message} = Backup.restore_json("not json at all")
      assert message =~ "not valid JSON"

      assert {:error, message} = Backup.restore_json(~s({"version":"1.0"}))
      assert message =~ "cannot be restored"

      # Nothing was deleted on the way to any of those errors.
      assert length(Invoices.list_invoices()) == 1
      assert length(Clients.list_clients()) == 1
    end

    test "a corrupt row aborts the restore instead of half-applying it" do
      client = client_fixture()
      invoice_fixture(client)

      corrupt =
        Backup.export_json()
        |> Jason.decode!()
        |> put_in(["invoices"], [%{"id" => 1, "invoice_date" => "not-a-date"}])
        |> Jason.encode!()

      assert {:error, message} = Backup.restore_json(corrupt)
      assert message =~ "invoice_date"

      # The transaction rolled back, so the data that was there is still there.
      assert length(Invoices.list_invoices()) == 1
    end
  end
end
