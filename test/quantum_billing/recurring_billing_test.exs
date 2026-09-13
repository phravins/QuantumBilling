defmodule QuantumBilling.RecurringBillingTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients
  alias QuantumBilling.Mail
  alias QuantumBilling.Recurring
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
      assert item.amount == 10_000
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

      assert {:ok, %{processed_count: count}} = RecurringInvoiceWorker.perform(%Oban.Job{})
      assert is_integer(count)
    end

    test "a job for a profile that no longer exists is discarded, not retried" do
      assert :discard =
               RecurringInvoiceWorker.perform(%Oban.Job{args: %{"profile_id" => 0}})
    end
  end
end
