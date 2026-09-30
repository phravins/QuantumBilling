defmodule QuantumBilling.ClientBinTest do
  @moduledoc """
  What moving a client to the Bin does, asked of every part of the application
  that reads clients.

  Kept apart from `ClientsTest`, which is about what makes a client valid, for
  the same reason `BinTest` is one file: the risk is a read that was missed, so
  the reads are listed together.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Recurring
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Reports

  @gstin "27AABCA1234A1Z5"

  defp client_fixture(overrides \\ %{}) do
    {:ok, client} =
      Clients.create_client(
        Map.merge(
          %{
            "client_type" => "Registered Business",
            "name" => "Acme Traders",
            "gstin" => @gstin,
            "phone" => "9876543210",
            "email" => "billing@acme.test",
            "billing_line1" => "123 Business Park",
            "billing_city" => "Mumbai",
            "billing_state" => "Maharashtra (27)",
            "billing_pin" => "400093"
          },
          overrides
        )
      )

    client
  end

  defp unregistered_fixture(name) do
    client_fixture(%{
      "client_type" => "Unregistered",
      "name" => name,
      "gstin" => nil,
      "email" => "accounts@kept.test"
    })
  end

  defp invoice_fixture(client) do
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
  end

  defp profile_fixture(client) do
    {:ok, profile} =
      Recurring.create_profile(%{
        title: "Monthly Retainer",
        frequency: "Monthly",
        next_run_date: Date.utc_today(),
        client_id: client.id,
        auto_send_email: false
      })

    profile
  end

  defp binned(client) do
    {:ok, binned} = Clients.delete_client(client)
    binned
  end

  describe "delete_client/2" do
    test "keeps the row, and the invoices raised for it still point at it" do
      client = client_fixture()
      invoice = invoice_fixture(client)

      assert {:ok, %Client{deleted_at: %DateTime{}}} = Clients.delete_client(client)

      assert Repo.get(Client, client.id)
      assert Repo.get(Invoice, invoice.id).client_id == client.id
    end

    test "takes the client out of the directory and the lookups" do
      kept = unregistered_fixture("Kept Traders")
      gone = binned(client_fixture())

      assert Enum.map(Clients.list_clients(), & &1.id) == [kept.id]
      assert %{total: 1, rows: [%Client{id: id}]} = Clients.page()
      assert id == kept.id
      assert %{total: 0} = Clients.page(search: "Acme")

      assert Clients.get_client(gone.id) == nil
      assert Clients.get_client(to_string(gone.id)) == nil
      assert Clients.get_client_by_name("Acme Traders") == nil
      assert_raise Ecto.NoResultsError, fn -> Clients.get_client!(gone.id) end

      # The one next to it is untouched.
      assert Clients.get_client(kept.id)
      assert Clients.get_client_by_name("kept traders")
    end

    test "takes the client out of the pickers" do
      kept = unregistered_fixture("Kept Traders")
      gone = binned(client_fixture())

      assert Enum.map(Clients.picker_options(), & &1.id) == [kept.id]
      assert Clients.picker_options("Acme") == []

      # An invoice that was raised for it and is being edited goes on showing
      # its own client, as it does for one the search does not match.
      assert gone.id in Enum.map(Clients.picker_options(nil, gone.id), & &1.id)
    end

    test "takes the client's name out of the report filter" do
      unregistered_fixture("Kept Traders")
      binned(client_fixture())

      names = Reports.client_names()

      assert "Kept Traders" in names
      refute "Acme Traders" in names
    end

    test "gives its GSTIN up, so the customer can be added again" do
      binned(client_fixture())

      assert {:ok, %Client{gstin: @gstin}} =
               Clients.create_client(%{
                 "client_type" => "Registered Business",
                 "name" => "Acme Traders (new)",
                 "gstin" => @gstin,
                 "phone" => "9876543210",
                 "billing_line1" => "123 Business Park",
                 "billing_city" => "Mumbai",
                 "billing_state" => "Maharashtra (27)",
                 "billing_pin" => "400093"
               })
    end

    test "is written to the audit trail against the user who did it" do
      user = QuantumBilling.AccountsFixtures.user_fixture()
      client = client_fixture()

      {:ok, _binned} = Clients.delete_client(client, user_id: user.id)

      assert [log] = Audit.list_audit_logs()
      assert log.action == "bin_client"
      assert log.resource_type == "Client"
      assert log.resource_id == to_string(client.id)
      assert log.user_id == user.id
      assert log.details["name"] == "Acme Traders"
    end

    test "tells the pages that are open" do
      client = client_fixture()
      Clients.subscribe()

      {:ok, _binned} = Clients.delete_client(client)

      assert_receive {:client_binned, %Client{deleted_at: %DateTime{}}}
    end

    test "is a no-op for a client that is already there" do
      gone = binned(client_fixture())

      assert {:ok, again} = Clients.delete_client(gone)
      assert again.deleted_at == gone.deleted_at
      assert length(Audit.list_audit_logs()) == 1
    end
  end

  describe "recurring billing for a binned client" do
    test "stops, and picks up again when the client is restored" do
      client = client_fixture()
      profile = profile_fixture(client)

      assert Enum.map(Recurring.due_profiles(), & &1.id) == [profile.id]

      gone = binned(client)

      assert Recurring.due_profiles() == []
      assert Recurring.enqueue_due_profiles() == 0

      # A job that was already queued when the client was deleted.
      assert {:skip, :client_deleted} = Recurring.process_profile(profile)

      # Nothing about the profile itself moved: it is still there, still
      # active, still on the same date.
      assert %RecurringProfile{status: "Active", next_run_date: date} =
               Recurring.get_profile(profile.id)

      assert date == profile.next_run_date

      {:ok, _restored} = Clients.restore_client(gone)

      assert Enum.map(Recurring.due_profiles(), & &1.id) == [profile.id]
    end

    test "a profile with no client at all is still swept, as it was before" do
      profile =
        Repo.insert!(%RecurringProfile{
          title: "Orphan",
          frequency: "Monthly",
          status: "Active",
          next_run_date: Date.utc_today()
        })

      assert Enum.map(Recurring.due_profiles(), & &1.id) == [profile.id]
    end
  end

  describe "restore_client/2" do
    test "puts the client back everywhere, as it was" do
      client = client_fixture()
      gone = binned(client)

      assert [%Client{id: id}] = Clients.list_deleted_clients()
      assert id == client.id

      Clients.subscribe()

      assert {:ok, %Client{deleted_at: nil}} = Clients.restore_client(gone)
      assert_receive {:client_restored, %Client{deleted_at: nil}}

      assert Clients.list_deleted_clients() == []
      assert Clients.get_deleted_client(client.id) == nil

      restored = Clients.get_client(client.id)
      assert restored.name == "Acme Traders"
      assert restored.gstin == @gstin
      assert Enum.map(Clients.picker_options(), & &1.id) == [client.id]
    end

    # Two live clients cannot share a GSTIN, and which of the two is the real
    # one is not something a restore should decide.
    test "is refused when its GSTIN has been registered to another client since" do
      gone = binned(client_fixture())
      client_fixture(%{"name" => "Acme Traders (new)"})

      assert {:error, :gstin_taken} = Clients.restore_client(gone)

      assert Clients.get_client(gone.id) == nil
      assert Clients.get_deleted_client(gone.id)
    end
  end

  describe "purge_client/2" do
    test "removes the client for good and leaves its invoices standing" do
      client = client_fixture()
      invoice = invoice_fixture(client)
      profile = profile_fixture(client)
      gone = binned(client)

      assert {:ok, _purged} = Clients.purge_client(gone)

      refute Repo.get(Client, client.id)
      assert Clients.list_deleted_clients() == []

      # The invoice keeps the name and GSTIN it was issued under; it just no
      # longer links to a client record.
      assert %Invoice{client_id: nil, client_name: "Acme Traders", client_gstin: @gstin} =
               Repo.get(Invoice, invoice.id)

      assert %RecurringProfile{client_id: nil} = Repo.get(RecurringProfile, profile.id)
    end

    # The delete that cannot be undone is only reachable through the Bin.
    test "refuses a client that is not in the Bin" do
      client = client_fixture()

      assert {:error, :not_in_bin} = Clients.purge_client(client)
      assert Repo.get(Client, client.id)
    end

    # A credit note is a tax document raised against a client, and the
    # database will not let it point at nobody.
    test "refuses a client that credit notes were raised against" do
      client = client_fixture()
      invoice = invoice_fixture(client)

      {:ok, _note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{
          "note_type" => "Credit",
          "reason" => "Returned",
          "grand_total" => Decimal.new("18000.00")
        })

      gone = binned(client)

      assert Clients.in_use?(gone)
      assert {:error, :in_use} = Clients.purge_client(gone)
      assert Repo.get(Client, client.id)
    end

    test "is written to the audit trail and announced" do
      gone = binned(unregistered_fixture("Walk-in Buyer"))
      Clients.subscribe()

      {:ok, _purged} = Clients.purge_client(gone)

      assert_receive {:client_purged, %Client{}}
      assert Enum.any?(Audit.list_audit_logs(), &(&1.action == "purge_client"))
    end
  end

  describe "get_deleted_client/1" do
    test "finds only what is in the Bin" do
      kept = unregistered_fixture("Kept Traders")
      gone = binned(client_fixture())

      assert %Client{name: "Acme Traders"} = Clients.get_deleted_client(gone.id)
      assert Clients.get_deleted_client(to_string(gone.id))
      assert Clients.get_deleted_client(kept.id) == nil
      assert Clients.get_deleted_client("not-an-id") == nil
    end
  end
end
