defmodule QuantumBilling.RecurringTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients
  alias QuantumBilling.Recurring

  defp create_client do
    {:ok, client} =
      Clients.create_client(%{
        client_type: "Registered Business",
        name: "Acme Corp",
        gstin: "27AAACA1234A1Z5",
        phone: "9876543210",
        billing_line1: "Main St",
        billing_city: "Mumbai",
        billing_state: "Maharashtra (27)",
        billing_pin: "400001"
      })

    client
  end

  test "create_profile/1 and list_profiles/0" do
    client = create_client()

    attrs = %{
      title: "Monthly Support Retainer",
      frequency: "Monthly",
      next_run_date: Date.utc_today(),
      client_id: client.id
    }

    assert {:ok, profile} = Recurring.create_profile(attrs)
    assert profile.title == "Monthly Support Retainer"
    assert profile.status == "Active"

    profiles = Recurring.list_profiles()
    assert Enum.any?(profiles, &(&1.id == profile.id))
  end

  test "process_due_profiles/0 generates invoices for due profiles and advances next_run_date" do
    client = create_client()
    today = Date.utc_today()

    {:ok, profile} =
      Recurring.create_profile(%{
        title: "Software Subscription",
        frequency: "Monthly",
        next_run_date: today,
        client_id: client.id,
        auto_send_email: false
      })

    assert [{:ok, invoice}] = Recurring.process_due_profiles()
    assert invoice.client_name == "Acme Corp"

    updated_profile = Recurring.get_profile!(profile.id)
    assert Date.compare(updated_profile.next_run_date, today) == :gt
  end
end
