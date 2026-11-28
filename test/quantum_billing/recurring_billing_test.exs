defmodule QuantumBilling.RecurringBillingTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices
  alias QuantumBilling.Mail
  alias QuantumBilling.Recurring
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Workers.RecurringInvoiceWorker

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

  defp profile_fixture(client, attrs \\ %{}) do
    {:ok, profile} =
      Recurring.create_profile(
        Map.merge(
          %{
            title: "Monthly Retainer",
            frequency: "Monthly",
            next_run_date: Date.utc_today(),
            client_id: client.id,
            auto_send_email: false
          },
          attrs
        )
      )

    profile
  end

  describe "advance_date/2" do
    test "steps by calendar months, not by 30 days" do
      assert Recurring.advance_date(~D[2026-01-31], "Monthly") == ~D[2026-02-28]
      assert Recurring.advance_date(~D[2026-02-28], "Monthly") == ~D[2026-03-28]
      assert Recurring.advance_date(~D[2026-01-15], "Quarterly") == ~D[2026-04-15]
      assert Recurring.advance_date(~D[2026-01-15], "Annually") == ~D[2027-01-15]
    end

    test "lands on the last day of a shorter month" do
      assert Recurring.advance_date(~D[2026-08-31], "Monthly") == ~D[2026-09-30]
      assert Recurring.advance_date(~D[2024-01-31], "Monthly") == ~D[2024-02-29]
    end

    test "a year of monthly billing issues twelve invoices, not thirteen" do
      dates =
        Enum.reduce(1..12, {~D[2026-01-01], []}, fn _step, {date, acc} ->
          next = Recurring.advance_date(date, "Monthly")
          {next, [next | acc]}
        end)
        |> elem(1)

      assert length(Enum.uniq(dates)) == 12
      assert List.first(dates) == ~D[2027-01-01]
    end
  end

  describe "process_profile/2" do
    test "issues the invoice and moves the schedule in one step" do
      client = client_fixture()
      profile = profile_fixture(client)
      today = Date.utc_today()

      assert {:ok, invoice} = Recurring.process_profile(profile, today)

      assert invoice.client_name == "Acme Corp"
      assert invoice.client_email == "billing@acme.test"
      assert invoice.remarks =~ "Monthly Retainer"
      assert invoice.invoice_date == today

      assert Recurring.get_profile!(profile.id).next_run_date ==
               Recurring.advance_date(today, "Monthly")
    end

    test "skips a profile whose schedule has already moved on" do
      client = client_fixture()
      profile = profile_fixture(client, %{next_run_date: Date.add(Date.utc_today(), 5)})

      assert {:skip, :not_due} = Recurring.process_profile(profile)
    end

    test "skips a paused profile" do
      client = client_fixture()
      profile = profile_fixture(client, %{status: "Paused"})

      assert {:skip, :not_active} = Recurring.process_profile(profile)
    end

    test "queues the invoice email instead of sending it inline" do
      client = client_fixture()
      profile = profile_fixture(client, %{auto_send_email: true})

      assert {:ok, invoice} = Recurring.process_profile(profile)

      assert [delivery] = Mail.list_recent_deliveries()
      assert delivery.invoice_id == invoice.id
      assert delivery.to_email == "billing@acme.test"
    end

    test "bills the stored line items when there are any" do
      client = client_fixture()

      items =
        Jason.encode!([
          %{
            "description" => "Support hours",
            "hsn_sac" => "998313",
            "quantity" => 4,
            "unit" => "Hrs",
            "rate" => 2_500,
            "tax_rate" => 18,
            "position" => 1
          }
        ])

      profile = profile_fixture(client, %{items_json: items})

      assert {:ok, invoice} = Recurring.process_profile(profile)

      invoice = Repo.preload(invoice, :items)
      assert [item] = invoice.items
      assert item.description == "Support hours"
      # Stored rates are rupees, read through the same cast as the form: 4 × ₹2,500.
      assert item.amount == 1_000_000
    end

    test "tracks consecutive failure, timestamp, and failure reason on billing error" do
      client = client_fixture()
      invalid_items = Jason.encode!([%{"description" => "", "quantity" => 0, "rate" => 100}])
      profile = profile_fixture(client, %{items_json: invalid_items})

      assert {:error, _reason} = Recurring.process_profile(profile)

      reloaded = Recurring.get_profile!(profile.id)
      assert reloaded.consecutive_failures == 1
      assert %DateTime{} = reloaded.last_failed_at
      assert reloaded.last_failure_reason =~ "description" or reloaded.last_failure_reason =~ "blank"
      assert reloaded.status == "Active"
    end

    test "trips circuit breaker and auto-pauses profile after 3 consecutive failures" do
      client = client_fixture()
      invalid_items = Jason.encode!([%{"description" => "", "quantity" => 0, "rate" => 100}])
      profile = profile_fixture(client, %{items_json: invalid_items})

      assert {:error, _} = Recurring.process_profile(profile)
      assert Recurring.get_profile!(profile.id).consecutive_failures == 1
      assert Recurring.get_profile!(profile.id).status == "Active"

      assert {:error, _} = Recurring.process_profile(profile)
      assert Recurring.get_profile!(profile.id).consecutive_failures == 2
      assert Recurring.get_profile!(profile.id).status == "Active"

      assert {:error, _} = Recurring.process_profile(profile)
      paused_profile = Recurring.get_profile!(profile.id)
      assert paused_profile.consecutive_failures == 3
      assert paused_profile.status == "Paused"

      # Paused profile is excluded from due_profiles sweeps
      assert Recurring.due_profiles() == []

      # Direct processing returns {:skip, :not_active}
      assert {:skip, :not_active} = Recurring.process_profile(paused_profile)
    end

    test "dispatches in-app warning notification on failure and error notification on circuit breaker" do
      client = client_fixture()
      invalid_items = Jason.encode!([%{"description" => "", "quantity" => 0, "rate" => 100}])
      profile = profile_fixture(client, %{items_json: invalid_items})

      assert {:error, _} = Recurring.process_profile(profile)
      %{notifications: [n1 | _]} = QuantumBilling.Notifications.feed()
      assert n1.severity == "warning"
      assert n1.title =~ "Recurring Billing Failed"

      assert {:error, _} = Recurring.process_profile(profile)
      assert {:error, _} = Recurring.process_profile(profile)

      %{notifications: notifications} = QuantumBilling.Notifications.feed()
      assert Enum.any?(notifications, fn n ->
               n.severity == "error" and n.title =~ "Recurring Billing Paused"
             end)
    end

    test "successful billing resets consecutive_failures and last_failure_reason" do
      client = client_fixture()
      profile = profile_fixture(client, %{consecutive_failures: 2, last_failure_reason: "Previous failure"})

      assert {:ok, _invoice} = Recurring.process_profile(profile)

      updated = Recurring.get_profile!(profile.id)
      assert updated.consecutive_failures == 0
      assert updated.last_failure_reason == nil
    end

    test "manually activating a paused profile resets failures and re-arms circuit breaker" do
      client = client_fixture()
      profile = profile_fixture(client, %{status: "Paused", consecutive_failures: 3, last_failure_reason: "Error"})

      assert {:ok, updated} = Recurring.update_profile(profile, %{status: "Active"})
      assert updated.status == "Active"
      assert updated.consecutive_failures == 0
      assert updated.last_failure_reason == nil
    end
  end

  describe "enqueue_due_profiles/1" do
    test "queues one job per due profile and skips the rest" do
      client = client_fixture()
      profile_fixture(client)

      profile_fixture(client, %{
        title: "Not due yet",
        next_run_date: Date.add(Date.utc_today(), 7)
      })

      profile_fixture(client, %{title: "Paused", status: "Paused"})

      assert Recurring.enqueue_due_profiles() == 1
    end

    test "the sweep reports how many it queued" do
      client = client_fixture()
      profile_fixture(client, %{title: "Due now"})

      assert {:ok, %{processed_count: count}} =
               RecurringInvoiceWorker.perform(%Oban.Job{args: %{"business_id" => 1}})

      assert is_integer(count)
    end

    test "a job for a profile that no longer exists is discarded, not retried" do
      assert :discard =
               RecurringInvoiceWorker.perform(%Oban.Job{args: %{"profile_id" => 0}})
    end
  end

  describe "a profile in the Bin" do
    test "leaves the list without being lost" do
      client = client_fixture()
      kept = profile_fixture(client, %{title: "Kept"})
      gone = profile_fixture(client, %{title: "Binned"})

      assert {:ok, binned} = Recurring.delete_profile(gone)
      assert %DateTime{} = binned.deleted_at

      assert Enum.map(Recurring.list_profiles(), & &1.id) == [kept.id]
      assert %{rows: [row]} = Recurring.page()
      assert row.id == kept.id

      assert Recurring.get_profile(gone.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Recurring.get_profile!(gone.id) end

      assert [%{id: id, client: %{name: "Acme Corp"}}] = Recurring.list_deleted_profiles()
      assert id == gone.id
      assert Recurring.get_deleted_profile(gone.id).title == "Binned"
      assert Recurring.get_deleted_profile(kept.id) == nil
      assert Recurring.get_deleted_profile("not-an-id") == nil
    end

    # The read that matters most: a profile somebody deleted must not go on
    # raising invoices against the client.
    test "stops billing" do
      client = client_fixture()
      profile = profile_fixture(client)
      {:ok, binned} = Recurring.delete_profile(profile)

      assert Recurring.due_profiles() == []
      assert Recurring.enqueue_due_profiles() == 0
      assert Recurring.process_due_profiles() == []

      # A job queued just before the profile was binned finds nothing to bill,
      # and a caller that still holds the struct is turned away as well.
      assert :discard =
               RecurringInvoiceWorker.perform(%Oban.Job{args: %{"profile_id" => profile.id}})

      assert {:skip, :deleted} = Recurring.process_profile(binned)
      assert Invoices.list_invoices() == []
    end

    test "is billed again once it is restored" do
      client = client_fixture()
      {:ok, binned} = client |> profile_fixture() |> Recurring.delete_profile()

      assert {:ok, restored} = Recurring.restore_profile(binned)
      assert restored.deleted_at == nil

      assert Recurring.list_deleted_profiles() == []
      assert Enum.map(Recurring.due_profiles(), & &1.id) == [restored.id]
      assert Recurring.enqueue_due_profiles() == 1
    end

    test "can be deleted for good, and only from the Bin" do
      client = client_fixture()
      profile = profile_fixture(client)

      assert {:error, :not_in_bin} = Recurring.purge_profile(profile)
      assert Repo.get(RecurringProfile, profile.id)

      {:ok, binned} = Recurring.delete_profile(profile)

      assert {:ok, _purged} = Recurring.purge_profile(binned)
      refute Repo.get(RecurringProfile, profile.id)
      assert Recurring.list_deleted_profiles() == []
    end

    test "each step is written to the audit trail" do
      client = client_fixture()
      profile = profile_fixture(client)

      {:ok, binned} = Recurring.delete_profile(profile)
      {:ok, restored} = Recurring.restore_profile(binned)
      {:ok, binned} = Recurring.delete_profile(restored)
      {:ok, _purged} = Recurring.purge_profile(binned)

      actions =
        Audit.list_audit_logs()
        |> Enum.filter(&(&1.resource_type == "RecurringProfile"))
        |> Enum.map(& &1.action)
        |> Enum.sort()

      assert actions == [
               "bin_recurring_profile",
               "bin_recurring_profile",
               "purge_recurring_profile",
               "recurring_profile_created",
               "restore_recurring_profile"
             ]
    end
  end
end
