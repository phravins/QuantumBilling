defmodule QuantumBilling.Settings do
  @moduledoc """
  The current business's settings: one row, or an unsaved struct of defaults while there is none.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit
  alias QuantumBilling.Compliance
  alias QuantumBilling.Currency
  alias QuantumBilling.Events
  alias QuantumBilling.InstallationSettings
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings.Organization

  @doc """
  Subscribes the caller to settings changes.
  """
  def subscribe, do: Events.subscribe(Events.settings_topic())

  @doc "The organisation's settings, or an unsaved struct with the defaults."
  def get_organization do
    Repo.one(from o in Organization, order_by: [asc: o.id], limit: 1) || %Organization{}
  end

  @doc "The ISO code of the currency the business bills in."
  def currency_code, do: Organization.currency_code(get_organization())

  @doc """
  Makes sure the settings row exists, and returns it.

  Call it before locking the row (e.g. invoice numbering): `FOR UPDATE` locks
  nothing on an empty table, and concurrent inserts would deadlock.
  """
  def ensure_organization do
    case Repo.one(from o in Organization, order_by: [asc: o.id], limit: 1) do
      nil ->
        %Organization{}
        |> Ecto.Changeset.change(%{})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :singleton)

        # Re-read: on a conflict the insert comes back without an id.
        Repo.one(from o in Organization, order_by: [asc: o.id], limit: 1)

      organization ->
        organization
    end
  end

  @doc """
  Builds a changeset for one section of the settings.
  """
  def change_organization(%Organization{} = organization, attrs, section) do
    organization |> Organization.changeset(attrs, section) |> guard_decimal_places()
  end

  @doc """
  Saves one section, inserting the row the first time: `{:ok, org}` or `{:error, changeset}`.

  What changed goes to the audit log, secrets only as "changed". Pass
  `audit: false` for the defaults a new business is seeded with.
  """
  def update_section(%Organization{} = organization, attrs, section, opts \\ []) do
    changeset = change_organization(organization, attrs, section)
    result = save(changeset, section)

    # Broadcast from the saving window, which has already re-rendered.
    with {:ok, saved} <- result do
      Events.broadcast_from(Events.settings_topic(), {:settings_updated, saved})
      if Keyword.get(opts, :audit, true), do: audit_section(changeset, section)
    end

    result
  end

  # Client amounts, money custom fields and their defaults are minor units of
  # the business currency, so moving between two and three decimal places
  # (INR to KWD) would scale them by ten. Allowed while there are none.
  defp guard_decimal_places(changeset) do
    with {:ok, label} <- Ecto.Changeset.fetch_change(changeset, :currency),
         true <- changeset.valid?,
         from = Organization.currency_code(changeset.data),
         to = Currency.code_from_label(label),
         true <- Currency.exponent(from) != Currency.exponent(to),
         true <- has_money_records?() do
      Ecto.Changeset.add_error(
        changeset,
        :currency,
        "can't move between two- and three-decimal currencies once you have clients, " <>
          "documents or default amounts on custom fields"
      )
    else
      _same_places_or_empty -> changeset
    end
  end

  defp has_money_records? do
    Enum.any?(
      [
        QuantumBilling.Clients.Client,
        QuantumBilling.Invoices.Invoice,
        QuantumBilling.Quotations.Quotation,
        QuantumBilling.Recurring.RecurringProfile
      ],
      &Repo.exists?/1
    ) or money_defaults?()
  end

  defp money_defaults? do
    from(d in QuantumBilling.CustomFields.FieldDefinition,
      where: d.type == "money",
      select: d.options
    )
    |> Repo.all()
    |> Enum.any?(&Map.has_key?(&1 || %{}, "default"))
  end

  @section_titles %{
    company: "Company profile",
    general: "General settings",
    invoice: "Invoice settings",
    e_way_bill: "E-way bill settings",
    tax: "Tax settings",
    customization: "Invoice customization",
    notifications: "Notifications",
    smtp: "SMTP server",
    backup: "Backup & restore",
    integrations: "Integrations",
    security: "Security & access",
    preferences: "Preferences"
  }

  @doc "The name a person knows a settings section by."
  def section_title(section),
    do:
      Map.get_lazy(@section_titles, section, fn ->
        section |> to_string() |> String.capitalize()
      end)

  defp audit_section(changeset, section) do
    changes = Audit.changes(changeset)

    if changes != %{} do
      Audit.log_event(:settings_updated, "Settings", to_string(section),
        label: section_title(section),
        changes: changes,
        details: %{section: to_string(section)}
      )
    end
  end

  # The Security section also holds the installation's sign-in rules, which
  # apply to every business: saved with the business's own fields, or neither.
  defp save(changeset, :security) do
    Repo.transaction(fn ->
      with {:ok, saved} <- Repo.insert_or_update(changeset),
           {:ok, _rules} <-
             InstallationSettings.update(
               InstallationSettings.get(),
               Map.take(saved, InstallationSettings.fields())
             ) do
        saved
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp save(changeset, _section), do: Repo.insert_or_update(changeset)

  @doc "`organization` with the installation's sign-in rules filled in, for the Security form."
  def with_installation_rules(%Organization{} = organization) do
    Map.merge(organization, Map.take(InstallationSettings.get(), InstallationSettings.fields()))
  end

  @doc "Financial years for the settings dropdown, newest first."
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
  """
  def next_invoice_number(%Organization{} = organization) do
    Organization.document_number(
      organization.invoice_prefix || "INV",
      organization.invoice_next_number || 1,
      organization.invoice_number_padding
    )
  end

  @doc """
  The number the next note of `note_type` (`"Credit"` or `"Debit"`) would get,
  e.g. `"CN-0001"`. Notes use the invoice padding.
  """
  def next_note_number(%Organization{} = organization, "Credit") do
    Organization.document_number(
      organization.credit_note_prefix || "CN",
      organization.credit_note_next_number || 1,
      organization.invoice_number_padding
    )
  end

  def next_note_number(%Organization{} = organization, "Debit") do
    Organization.document_number(
      organization.debit_note_prefix || "DN",
      organization.debit_note_next_number || 1,
      organization.invoice_number_padding
    )
  end

  @doc """
  The number the next quotation would get, e.g. `"QT-0001"`. Quotations use
  the invoice padding.
  """
  def next_quotation_number(%Organization{} = organization) do
    Organization.document_number(
      organization.quotation_prefix || "QT",
      organization.quotation_next_number || 1,
      organization.invoice_number_padding
    )
  end
end
