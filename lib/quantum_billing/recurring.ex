defmodule QuantumBilling.Recurring do
  @moduledoc """
  Recurring billing profiles.

  `enqueue_due_profiles/0` runs daily and queues one job per due profile, so
  one failure doesn't block the rest. Double billing is prevented by job
  uniqueness and by advancing `next_run_date` in the invoice transaction.
  Deleting moves a profile to the Bin, where it stops billing.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias QuantumBilling.Audit
  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices
  alias QuantumBilling.Paging
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Repo
  alias QuantumBilling.Workers.RecurringInvoiceWorker

  @default_per_page 10
  @max_per_page 200

  @doc "Lists profiles, soonest first. Unbounded; the page uses `page/1`."
  def list_profiles do
    Repo.all(
      from p in RecurringProfile.kept(), order_by: [asc: p.next_run_date], preload: [:client]
    )
  end

  @doc "One page of profiles, soonest first."
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)

    result =
      RecurringProfile.kept()
      |> status_where(Keyword.get(opts, :status))
      # The id breaks ties so paging is stable.
      |> Paging.page(&order_by(&1, [p], asc: p.next_run_date, asc: p.id),
        page: Keyword.get(opts, :page, 1),
        per_page: per_page
      )

    %{result | rows: Repo.preload(result.rows, :client)}
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query
  defp status_where(query, status), do: where(query, [p], p.status == ^status)

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  @doc "Gets a profile by id, raising when it does not exist or is in the Bin."
  def get_profile!(id) do
    RecurringProfile.kept()
    |> Repo.get!(id)
    |> Repo.preload(:client)
  end

  @doc "Gets a profile by id, or `nil`. A profile in the Bin is `nil` here."
  def get_profile(id), do: fetch_by_id(RecurringProfile.kept(), id)

  @doc "Gets a profile that is in the Bin, or `nil`."
  def get_deleted_profile(id), do: fetch_by_id(RecurringProfile.binned(), id)

  @doc "Every profile in the Bin, most recently binned first."
  def list_deleted_profiles do
    Repo.all(
      from p in RecurringProfile.binned(),
        order_by: [desc: p.deleted_at, desc: p.id],
        preload: [:client]
    )
  end

  defp fetch_by_id(query, id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        case Repo.get(query, int_id) do
          nil -> nil
          profile -> Repo.preload(profile, :client)
        end

      _not_an_id ->
        nil
    end
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
  Moves a profile to the Bin. It stops billing; its schedule is kept.

  `opts` may carry `:user_id` for the audit entry.
  """
  def delete_profile(%RecurringProfile{} = profile, opts \\ []) do
    profile
    |> RecurringProfile.bin_changeset()
    |> Repo.update()
    |> audited(:bin_recurring_profile, opts)
  end

  @doc "Restores a profile. If overdue, it bills once on the next sweep."
  def restore_profile(%RecurringProfile{} = profile, opts \\ []) do
    profile
    |> RecurringProfile.restore_changeset()
    |> Repo.update()
    |> audited(:restore_recurring_profile, opts)
  end

  @doc "Deletes a binned profile for good. Its invoices are untouched."
  def purge_profile(profile, opts \\ [])

  def purge_profile(%RecurringProfile{deleted_at: nil}, _opts), do: {:error, :not_in_bin}

  def purge_profile(%RecurringProfile{} = profile, opts) do
    profile
    |> Repo.delete()
    |> audited(:purge_recurring_profile, opts)
  end

  defp audited({:ok, profile} = result, action, opts) do
    Audit.log_event(action, "RecurringProfile", profile.id,
      user_id: Keyword.get(opts, :user_id),
      details: %{title: profile.title, frequency: profile.frequency}
    )

    result
  end

  defp audited({:error, _changeset} = result, _action, _opts), do: result

  @doc "Profiles due to bill on `date`. Profiles of binned clients are skipped."
  def due_profiles(date \\ Date.utc_today()) do
    Repo.all(
      from p in RecurringProfile.kept(),
        left_join: c in assoc(p, :client),
        where: p.status == "Active" and p.next_run_date <= ^date,
        where: is_nil(c.deleted_at),
        order_by: [asc: p.next_run_date, asc: p.id],
        preload: [:client]
    )
  end

  @doc "Queues one billing job per due profile and returns the count."
  def enqueue_due_profiles(date \\ Date.utc_today()) do
    date
    |> due_profiles()
    |> Enum.reduce(0, fn profile, queued ->
      case %{"profile_id" => profile.id} |> RecurringInvoiceWorker.new() |> Oban.insert() do
        # Already queued by an earlier sweep.
        {:ok, %Oban.Job{conflict?: true}} ->
          queued

        {:ok, _job} ->
          queued + 1

        {:error, reason} ->
          Logger.error("[Recurring] could not queue profile #{profile.id}: #{inspect(reason)}")

          queued
      end
    end)
  end

  @doc "Bills every due profile inline. For consoles and tests."
  def process_due_profiles(date \\ Date.utc_today()) do
    date
    |> due_profiles()
    |> Enum.map(&process_profile(&1, date))
  end

  @doc """
  Issues a profile's invoice and advances its schedule: `{:ok, inv}`, `{:skip, reason}` or `{:error, reason}`.
  """
  def process_profile(profile, today \\ Date.utc_today())

  # Binned after the sweep queued it.
  def process_profile(%RecurringProfile{deleted_at: %DateTime{}}, _today) do
    {:skip, :deleted}
  end

  def process_profile(%RecurringProfile{status: status}, _today) when status != "Active" do
    {:skip, :not_active}
  end

  def process_profile(%RecurringProfile{} = profile, today) do
    profile = Repo.preload(profile, :client)

    cond do
      is_nil(profile.next_run_date) ->
        {:skip, :no_schedule}

      Date.compare(profile.next_run_date, today) == :gt ->
        {:skip, :not_due}

      is_nil(profile.client) ->
        {:skip, :client_missing}

      not is_nil(profile.client.deleted_at) ->
        {:skip, :client_deleted}

      true ->
        bill(profile, today)
    end
  end

  defp bill(%RecurringProfile{} = profile, today) do
    client = profile.client

    Multi.new()
    |> Multi.run(:invoice, fn _repo, _changes ->
      Invoices.create_invoice(invoice_attrs(profile, client, today))
    end)
    # Same transaction as the invoice, so a cycle is never billed twice.
    |> Multi.update(:profile, fn _changes ->
      RecurringProfile.changeset(profile, %{
        next_run_date: advance_date(profile.next_run_date || today, profile.frequency)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invoice: invoice}} ->
        maybe_queue_email(profile, client, invoice)
        {:ok, invoice}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Queued, not sent: a mail failure must not roll back the billing.
  defp maybe_queue_email(%RecurringProfile{auto_send_email: true}, client, invoice) do
    if is_binary(client.email) and String.trim(client.email) != "" do
      case InvoiceNotifier.deliver_invoice_pdf_async(client.email, invoice) do
        {:ok, _delivery} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Recurring] invoice #{invoice.invoice_number} could not be queued for " <>
              "email: #{inspect(reason)}"
          )
      end
    end
  end

  defp maybe_queue_email(_profile, _client, _invoice), do: :ok

  defp invoice_attrs(%RecurringProfile{} = profile, client, today) do
    %{
      client_id: client.id,
      client_name: client.name,
      client_gstin: client.gstin,
      client_email: client.email,
      client_state: client.billing_state,
      client_billing_address: billing_address(client),
      place_of_supply: client.billing_state,
      invoice_date: today,
      due_date: Date.add(today, client.payment_terms_days || 30),
      remarks: "Generated automatically from recurring profile: #{profile.title}",
      items: items(profile)
    }
  end

  defp billing_address(client) do
    [client.billing_line1, client.billing_line2, client.billing_city, client.billing_state]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
    |> then(fn address ->
      case client.billing_pin do
        pin when is_binary(pin) and pin != "" -> address <> " - " <> pin
        _no_pin -> address
      end
    end)
  end

  # A profile with no items bills a single line for its title.
  defp items(%RecurringProfile{items_json: json, title: title}) do
    case Jason.decode(json || "[]") do
      {:ok, [_ | _] = parsed} ->
        parsed

      _empty_or_invalid ->
        [
          %{
            "description" => title,
            "hsn_sac" => "998314",
            "quantity" => 1,
            "unit" => "Nos",
            "rate" => 10_000,
            "tax_rate" => 18,
            "position" => 1
          }
        ]
    end
  end

  @doc "The next billing date after `date`, stepping calendar months (31 Jan → 28 Feb → 31 Mar)."
  def advance_date(%Date{} = date, "Monthly"), do: add_months(date, 1)
  def advance_date(%Date{} = date, "Quarterly"), do: add_months(date, 3)
  def advance_date(%Date{} = date, "Annually"), do: add_months(date, 12)
  def advance_date(%Date{} = date, _unknown_frequency), do: add_months(date, 1)

  defp add_months(%Date{} = date, months) do
    total = date.year * 12 + (date.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    day = min(date.day, Date.days_in_month(%Date{date | year: year, month: month, day: 1}))

    Date.new!(year, month, day)
  end
end
