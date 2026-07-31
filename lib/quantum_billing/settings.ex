defmodule QuantumBilling.Settings do
  @moduledoc """
  The organisation's settings.

  There is exactly one settings row. `get_organization/0` returns it, or an
  unsaved struct carrying the schema defaults when the table is still empty, so
  the Settings page renders on a fresh database rather than crashing on `nil`.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Compliance
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings.Organization

  @doc """
  The organisation's settings, or an unsaved struct with the defaults.

  The returned struct is only persisted once something is saved, so a fresh
  install shows sensible defaults without writing a row nobody asked for.
  """
  def get_organization do
    Repo.one(from o in Organization, order_by: [asc: o.id], limit: 1) || %Organization{}
  end

  @doc """
  Builds a changeset for one section of the settings.
  """
  def change_organization(%Organization{} = organization, attrs \\ %{}, section) do
    Organization.changeset(organization, attrs, section)
  end

  @doc """
  Saves one section, inserting the row the first time and updating it after.

  Returns `{:ok, organization}` or `{:error, changeset}`.
  """
  def update_section(%Organization{} = organization, attrs, section) do
    organization
    |> Organization.changeset(attrs, section)
    |> Repo.insert_or_update()
  end

  @doc """
  Financial years for the settings dropdown, newest first.

  Derived from `QuantumBilling.Compliance.financial_year/1` rather than
  hardcoded, so the list stays correct as years pass.
  """
  def financial_years(today \\ Date.utc_today(), back \\ 3, forward \\ 1) do
    {current_start, _} = Compliance.financial_year(today)

    for offset <- forward..-back//-1 do
      start_year = current_start.year + offset
      short = start_year |> Kernel.+(1) |> to_string() |> String.slice(2..3)

      "#{start_year}-#{short} (Apr #{start_year} - Mar #{start_year + 1})"
    end
  end

  @doc """
  The invoice number that would be issued next, e.g. `"INV-0001"`.

  Shown on the Invoice panel so the prefix, padding and next-number fields have
  a visible consequence.
  """
  def next_invoice_number(%Organization{} = organization) do
    prefix = organization.invoice_prefix || "INV"
    number = organization.invoice_next_number || 1
    padding = organization.invoice_number_padding || 0

    "#{prefix}-#{number |> to_string() |> String.pad_leading(padding, "0")}"
  end
end
