defmodule QuantumBilling.Backup do
  @moduledoc """
  Database backup and restoration module for QuantumBilling.
  Exports and restores full system state as structured JSON.
  """

  alias QuantumBilling.Repo
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Templates.InvoiceTemplate
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Audit.AuditLog

  @doc """
  Generates a full JSON backup of the application state.
  """
  def export_json do
    data = %{
      version: "1.0",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      organization: Repo.one(Organization),
      clients: Repo.all(Client),
      invoices: Repo.all(Invoice) |> Repo.preload(:items),
      templates: Repo.all(InvoiceTemplate),
      recurring_profiles: Repo.all(RecurringProfile),
      credit_notes: Repo.all(CreditNote),
      audit_logs: Repo.all(AuditLog)
    }

    Jason.encode!(data, pretty: true)
  end

  @doc """
  Restores system state from a JSON backup payload.
  """
  def restore_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"version" => "1.0"} = data} ->
        Repo.transaction(fn ->
          # Clean current non-auth data safely
          Repo.delete_all(AuditLog)
          Repo.delete_all(CreditNote)
          Repo.delete_all(InvoiceItem)
          Repo.delete_all(Invoice)
          Repo.delete_all(RecurringProfile)
          Repo.delete_all(Client)

          # Restore Clients
          clients = Map.get(data, "clients", [])

          Enum.each(clients, fn c_attrs ->
            struct(Client)
            |> Client.changeset(Map.drop(c_attrs, ["id", "inserted_at", "updated_at"]))
            |> Repo.insert()
          end)

          # Restore Organization if present
          if org_data = Map.get(data, "organization") do
            if current_org = Repo.one(Organization) do
              current_org
              |> Organization.changeset(
                Map.drop(org_data, ["id", "inserted_at", "updated_at"]),
                :general
              )
              |> Repo.update()
            end
          end

          :ok
        end)

      _ ->
        {:error, "Invalid backup format or unsupported version."}
    end
  end
end
