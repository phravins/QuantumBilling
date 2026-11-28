defmodule QuantumBilling.Workers.PaymentReminderWorkerTest do
  use QuantumBilling.DataCase, async: false

  import Ecto.Query

  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.PaymentReminder
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.PaymentReminderWorker

  @today ~D[2026-11-25]

  defp store_settings(attrs) do
    Settings.ensure_organization()
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp client_fixture(attrs \\ %{}) do
    defaults = %{
      "client_type" => "Unregistered",
      "name" => "Reminder Test Client",
      "phone" => "9876543210",
      "email" => "client@example.com",
      "billing_line1" => "1 Main Street",
      "billing_city" => "Mumbai",
      "billing_state" => "Maharashtra (27)",
      "billing_pin" => "400001"
    }

    {:ok, client} = Clients.create_client(Map.merge(defaults, attrs))
    client
  end

  defp invoice_fixture(client, attrs \\ %{}) do
    defaults = %{
      invoice_number: "REM-#{System.unique_integer([:positive])}",
      invoice_type: "Tax Invoice",
      invoice_date: @today,
      due_date: @today,
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      company_name: "Quantum Billing",
      client_id: client.id,
      client_name: client.name,
      client_email: client.email,
      grand_total: 11_800,
      status: "E-Invoice Generated"
    }

    Repo.insert!(struct(Invoice, Map.merge(defaults, attrs)))
  end

  defp run_worker do
    PaymentReminderWorker.process(%Oban.Job{
      args: %{"today" => Date.to_iso8601(@today)}
    })
  end

  defp reminders do
    Repo.all(from r in PaymentReminder, order_by: [asc: r.id])
  end

  describe "process/1" do
    test "does not queue reminders when the feature is disabled" do
      store_settings(%{payment_reminders_enabled: false})

      client = client_fixture()
      invoice_fixture(client)

      assert {:ok, %{queued: 0, disabled: true}} = run_worker()
      assert reminders() == []
    end

    test "queues a reminder for an unpaid invoice due today" do
      store_settings(%{
        payment_reminders_enabled: true,
        payment_reminder_days: [0]
      })

      client = client_fixture()
      invoice = invoice_fixture(client)

      assert {:ok, %{queued: 1}} = run_worker()

      assert [%PaymentReminder{} = reminder] = reminders()
      assert reminder.invoice_id == invoice.id
      assert reminder.step == 0
    end

    test "does not queue reminders for clients who opted out" do
      store_settings(%{
        payment_reminders_enabled: true,
        payment_reminder_days: [0]
      })

      opted_out_client =
        client_fixture(%{
          "name" => "Opted Out Client",
          "email" => "optout@example.com",
          "reminders_opt_out" => true
        })

      invoice_fixture(opted_out_client)

      assert {:ok, %{queued: 0}} = run_worker()
      assert reminders() == []
    end

    test "does not queue duplicate reminders when run twice" do
      store_settings(%{
        payment_reminders_enabled: true,
        payment_reminder_days: [0]
      })

      client = client_fixture()
      invoice_fixture(client)

      assert {:ok, %{queued: 1}} = run_worker()
      assert {:ok, %{queued: 0}} = run_worker()

      assert length(reminders()) == 1
    end

    test "does not queue reminders for paid invoices" do
      store_settings(%{
        payment_reminders_enabled: true,
        payment_reminder_days: [0]
      })

      client = client_fixture()
      invoice_fixture(client, %{status: "Paid"})

      assert {:ok, %{queued: 0}} = run_worker()
      assert reminders() == []
    end

    test "uses the configured offset relative to the due date" do
      store_settings(%{
        payment_reminders_enabled: true,
        payment_reminder_days: [-3]
      })

      client = client_fixture()
      invoice_fixture(client, %{due_date: Date.add(@today, 3)})

      assert {:ok, %{queued: 1}} = run_worker()

      assert [%PaymentReminder{step: -3}] = reminders()
    end
  end
end
