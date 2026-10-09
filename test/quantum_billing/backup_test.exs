defmodule QuantumBilling.BackupTest do
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Backup
  alias QuantumBilling.Clients
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Recurring
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

      assert data["version"] == "2.1"
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

    # What is in the Bin is still data the business holds. A restore that
    # dropped `deleted_at` would put every deleted invoice back on the books.
    test "what was in the Bin is still in the Bin afterwards" do
      client = client_fixture()
      kept = invoice_fixture(client)
      {:ok, binned} = client |> invoice_fixture() |> Invoices.delete_invoice()

      {:ok, profile} =
        Recurring.create_profile(%{
          title: "Monthly Retainer",
          frequency: "Monthly",
          next_run_date: Date.utc_today(),
          client_id: client.id,
          auto_send_email: false
        })

      {:ok, binned_profile} = Recurring.delete_profile(profile)

      json = Backup.export_json()

      # Emptied between the export and the restore, so that what comes back
      # can only have come from the file.
      {:ok, _restored} = Invoices.restore_invoice(binned)
      {:ok, _restored} = Recurring.restore_profile(binned_profile)
      assert Invoices.list_deleted_invoices() == []

      assert {:ok, counts} = Backup.restore_json(json)
      assert counts.invoices == 2

      assert [%{id: kept_id}] = Invoices.list_invoices()
      assert kept_id == kept.id

      assert [%Invoice{id: binned_id, deleted_at: deleted_at}] = Invoices.list_deleted_invoices()
      assert binned_id == binned.id
      assert deleted_at == binned.deleted_at

      assert Recurring.list_profiles() == []
      assert [%{id: profile_id}] = Recurring.list_deleted_profiles()
      assert profile_id == profile.id
      assert Recurring.due_profiles() == []
    end

    # The same for the two kinds that reached the Bin later. A restore that
    # dropped `deleted_at` here would put a deleted customer back in every
    # picker, and have a deleted e-way bill claim its invoice again.
    test "a client and an e-way bill that were in the Bin are still in it afterwards" do
      kept = client_fixture()

      {:ok, binned_client} =
        %{client_type: "Unregistered", name: "Old Customer", gstin: nil}
        |> client_fixture()
        |> Clients.delete_client()

      {:ok, bill} =
        EWayBills.generate_e_way_bill(invoice_fixture(kept), %{
          "distance_km" => "180",
          "vehicle_number" => "MH04CD5678"
        })

      {:ok, binned_bill} = EWayBills.delete_e_way_bill(bill)

      json = Backup.export_json()

      # Emptied between the export and the restore, so that what comes back
      # can only have come from the file.
      {:ok, _restored} = Clients.restore_client(binned_client)
      {:ok, _restored} = EWayBills.restore_e_way_bill(binned_bill)
      assert Clients.list_deleted_clients() == []
      assert EWayBills.list_deleted_e_way_bills() == []

      assert {:ok, _counts} = Backup.restore_json(json)

      assert Enum.map(Clients.list_clients(), & &1.id) == [kept.id]
      assert [%{id: client_id, deleted_at: client_deleted_at}] = Clients.list_deleted_clients()
      assert client_id == binned_client.id
      assert client_deleted_at == binned_client.deleted_at

      assert EWayBills.list_e_way_bills() == []
      assert [%{id: bill_id, deleted_at: bill_deleted_at}] = EWayBills.list_deleted_e_way_bills()
      assert bill_id == bill.id
      assert bill_deleted_at == binned_bill.deleted_at
      assert EWayBills.live_bill_for_invoice(bill.invoice_id) == nil
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

    test "restores a 2.0 file, moving its invoice e-way bill columns into rows" do
      client = client_fixture()
      invoice = invoice_fixture(client)

      # What a 2.0 export looked like: the bill lived on the invoice, in eight
      # columns that no longer exist on the schema. Users still hold these
      # files, so refusing them would destroy working backups.
      legacy =
        Backup.export_json()
        |> Jason.decode!()
        |> Map.put("version", "2.0")
        |> Map.delete("e_way_bills")
        |> Map.delete("e_way_bill_part_b_updates")
        |> update_in(["invoices"], fn [row] ->
          [
            Map.merge(row, %{
              "ewb_number" => "391000123456",
              "ewb_date" => "2026-03-01",
              "ewb_valid_until" => "2026-03-03T00:00:00",
              "distance_km" => 320,
              "mode_of_transport" => "Road",
              "vehicle_number" => "MH12AB1234",
              "transporter_id" => "27AAACG1234A1ZP",
              "transporter_name" => "Blue Dart"
            })
          ]
        end)
        |> Jason.encode!()

      assert {:ok, counts} = Backup.restore_json(legacy)
      assert counts.e_way_bills == 1

      assert [bill] = Repo.all(QuantumBilling.EWayBills.EWayBill)
      assert bill.ewb_number == "391000123456"
      assert bill.distance_km == 320
      assert bill.vehicle_number == "MH12AB1234"
      assert bill.transporter_name == "Blue Dart"
      assert bill.status == "Active"
      assert bill.invoice_id == invoice.id
      assert bill.valid_until == ~N[2026-03-03 00:00:00]
    end

    test "a 2.0 file with no e-way bill on its invoices restores no bills" do
      client = client_fixture()
      invoice_fixture(client)

      legacy =
        Backup.export_json()
        |> Jason.decode!()
        |> Map.put("version", "2.0")
        |> Map.delete("e_way_bills")
        |> Jason.encode!()

      assert {:ok, counts} = Backup.restore_json(legacy)
      assert counts.e_way_bills == 0
      assert counts.invoices == 1
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

  describe "stream_json/2" do
    test "produces the same document export_json/0 does" do
      client = client_fixture()
      invoice_fixture(client)

      {:ok, iodata} = Backup.stream_json(fn chunk, acc -> [acc | chunk] end, [])

      streamed = iodata |> IO.iodata_to_binary() |> Jason.decode!()
      whole = Backup.export_json() |> Jason.decode!()

      # `generated_at` is the moment of the call, so it is the one field the
      # two are entitled to disagree on.
      assert Map.delete(streamed, "generated_at") == Map.delete(whole, "generated_at")
    end

    test "emits the file in pieces, starting before the data is gathered" do
      client = client_fixture()
      for _ <- 1..25, do: invoice_fixture(client)

      {:ok, chunks} =
        Backup.stream_json(fn chunk, acc -> [IO.iodata_to_binary(chunk) | acc] end, [])

      chunks = Enum.reverse(chunks)

      # The whole point of the rework: the download starts on the first chunk
      # and the file is never assembled in memory. `export_json/0` at fifty
      # thousand invoices held a hundred megabytes of binary at once and took
      # thirty-six seconds before the browser saw a byte.
      assert length(chunks) > 25
      assert hd(chunks) =~ ~s("version":"2.1")

      document = chunks |> Enum.join() |> Jason.decode!()
      assert length(document["invoices"]) == 25
    end

    test "is valid JSON for an empty database" do
      Repo.delete_all(QuantumBilling.Invoices.InvoiceItem)
      Repo.delete_all(Invoice)
      Repo.delete_all(QuantumBilling.Clients.Client)

      # An empty section is `[]`, not a stray comma — the separator handling is
      # what usually gets this wrong.
      document = Backup.export_json() |> Jason.decode!()

      assert document["clients"] == []
      assert document["invoices"] == []
      assert document["invoice_items"] == []
    end
  end

  describe "restore_json/1 at volume" do
    test "inserts in batches rather than one statement per section" do
      client = client_fixture()
      # Postgres refuses a statement with more than 65,535 parameters, so a
      # single `insert_all` over a real backup's invoices fails outright. These
      # are few enough to be quick and many enough to cross a batch boundary.
      for _ <- 1..120, do: invoice_fixture(client)

      json = Backup.export_json()

      Repo.delete_all(QuantumBilling.Invoices.InvoiceItem)
      Repo.delete_all(Invoice)
      Repo.delete_all(QuantumBilling.Clients.Client)

      assert {:ok, counts} = Backup.restore_json(json)

      assert counts.invoices == 120
      assert counts.invoice_items == 120
      assert Repo.aggregate(Invoice, :count, :id) == 120
    end
  end
end
