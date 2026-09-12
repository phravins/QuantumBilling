defmodule QuantumBilling.Recurring do
  @moduledoc """
  The Recurring Billing context.

  Handles creation, listing, updating, and execution of automated recurring invoice profiles.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Clients
  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Repo

  @doc """
  Lists all recurring profiles, ordered by next_run_date.
  """
  def list_profiles do
    Repo.all(from p in RecurringProfile, order_by: [asc: p.next_run_date], preload: [:client])
  end

  @doc """
  Gets a recurring profile by ID.
  """
  def get_profile!(id) do
    RecurringProfile
    |> Repo.get!(id)
    |> Repo.preload(:client)
  end

  @doc """
  Builds a changeset for a recurring profile.
  """
  def change_profile(%RecurringProfile{} = profile \\ %RecurringProfile{}, attrs \\ %{}) do
    RecurringProfile.changeset(profile, attrs)
  end

  @doc """
  Creates a recurring profile.
  """
  def create_profile(attrs) do
    %RecurringProfile{}
    |> RecurringProfile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a recurring profile.
  """
  def update_profile(%RecurringProfile{} = profile, attrs) do
    profile
    |> RecurringProfile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a recurring profile.
  """
  def delete_profile(%RecurringProfile{} = profile) do
    Repo.delete(profile)
  end

  @doc """
  Processes all active profiles that are due today or overdue.
  Generates the invoice, sends the email with PDF attachment if auto_send_email is enabled,
  and advances the next_run_date.
  """
  def process_due_profiles do
    today = Date.utc_today()

    due_profiles =
      Repo.all(
        from p in RecurringProfile,
          where: p.status == "Active" and p.next_run_date <= ^today,
          preload: [:client]
      )

    Enum.map(due_profiles, &process_single_profile(&1, today))
  end

  defp process_single_profile(%RecurringProfile{} = profile, today) do
    client = profile.client || Clients.get_client!(profile.client_id)

    # Parse items JSON or use default line item
    items =
      case Jason.decode(profile.items_json || "[]") do
        {:ok, parsed} when is_list(parsed) and parsed != [] ->
          parsed

        _ ->
          [
            %{
              "description" => profile.title,
              "hsn_sac" => "998314",
              "quantity" => 1,
              "unit" => "Nos",
              "rate" => 10000,
              "tax_rate" => 18,
              "position" => 1
            }
          ]
      end

    invoice_attrs = %{
      client_id: client.id,
      client_name: client.name,
      client_gstin: client.gstin,
      client_billing_address:
        "#{client.billing_line1}, #{client.billing_city}, #{client.billing_state} - #{client.billing_pin}",
      place_of_supply: client.billing_state,
      invoice_date: today,
      due_date: Date.add(today, client.payment_terms_days || 30),
      status: "Draft",
      items: items
    }

    case Invoices.create_invoice(invoice_attrs) do
      {:ok, invoice} ->
        if profile.auto_send_email and client.email in [nil, ""] == false do
          _ = InvoiceNotifier.deliver_invoice_pdf(client.email, invoice)
        end

        next_date = advance_date(profile.next_run_date || today, profile.frequency)
        update_profile(profile, %{next_run_date: next_date})
        {:ok, invoice}

      error ->
        error
    end
  end

  defp advance_date(%Date{} = date, "Monthly"), do: Date.add(date, 30)
  defp advance_date(%Date{} = date, "Quarterly"), do: Date.add(date, 90)
  defp advance_date(%Date{} = date, "Annually"), do: Date.add(date, 365)
  defp advance_date(%Date{} = date, _), do: Date.add(date, 30)
end
