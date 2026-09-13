defmodule QuantumBilling.Recurring do
  @moduledoc """
  Recurring billing profiles: a client, a schedule, and the lines to bill.

  ## How a profile gets billed

  `enqueue_due_profiles/0` runs daily from the Oban Cron plugin and queues one
  job per due profile; each job calls `process_profile/1`. Fanning out this way
  means a profile whose client has been deleted, or whose items no longer
  validate, fails its own job and is retried on its own — it does not take the
  rest of the morning's billing down with it, which a single `Enum.map/2` over
  every due profile did.

  ## Billing twice is the thing to avoid

  Issuing an invoice is not an operation anybody wants repeated: it consumes a
  number in a statutory series, and it mails a customer. Three things guard
  against it — the job's uniqueness window, `next_run_date` being advanced in
  the same transaction that issues the invoice, and the `:skip` path below for
  a profile whose date has already moved on.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias QuantumBilling.InvoiceNotifier
  alias QuantumBilling.Invoices
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Repo
  alias QuantumBilling.Workers.RecurringInvoiceWorker

  @doc """
  Lists profiles, soonest first.
  """
  def list_profiles do
    Repo.all(from p in RecurringProfile, order_by: [asc: p.next_run_date], preload: [:client])
  end

  @doc "Gets a profile by id, raising when it does not exist."
  def get_profile!(id) do
    RecurringProfile
    |> Repo.get!(id)
    |> Repo.preload(:client)
  end

  @doc "Gets a profile by id, or `nil`."
  def get_profile(id) do
    case Repo.get(RecurringProfile, id) do
      nil -> nil
      profile -> Repo.preload(profile, :client)
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
  Deletes a recurring profile.
  """
  def delete_profile(%RecurringProfile{} = profile) do
    Repo.delete(profile)
  end

  @doc """
  The profiles that are due to bill on `date`.
  """
  def due_profiles(date \\ Date.utc_today()) do
    Repo.all(
      from p in RecurringProfile,
        where: p.status == "Active" and p.next_run_date <= ^date,
        order_by: [asc: p.next_run_date, asc: p.id],
        preload: [:client]
    )
  end

  @doc """
  Queues one billing job per due profile, returning how many were queued.

  The queue — rather than a loop — is what makes this safe to call from a
  scheduled job: each profile's work is retried on its own, and a node dying
  mid-sweep leaves the outstanding jobs to be picked up rather than skipped.
  """
  def enqueue_due_profiles(date \\ Date.utc_today()) do
    date
    |> due_profiles()
    |> Enum.reduce(0, fn profile, queued ->
      case %{"profile_id" => profile.id} |> RecurringInvoiceWorker.new() |> Oban.insert() do
        # A profile already queued by an earlier sweep comes back as a
        # conflict, which is the uniqueness rule doing its job rather than a
        # failure.
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

  @doc """
  Bills every due profile in line, returning a result per profile.

  Kept for direct use — a console, a test, a one-off catch-up — where the
  answer is wanted immediately rather than through the queue. Scheduled billing
  goes through `enqueue_due_profiles/0`.
  """
  def process_due_profiles(date \\ Date.utc_today()) do
    date
    |> due_profiles()
    |> Enum.map(&process_profile(&1, date))
  end

  @doc """
  Issues the invoice a profile is due for and moves its schedule forward.

  Returns `{:ok, invoice}`, `{:skip, reason}` when the profile is not due or no
  longer billable, or `{:error, reason}`.
  """
  def process_profile(profile, today \\ Date.utc_today())

  def process_profile(%RecurringProfile{status: status}, _today) when status != "Active" do
    {:skip, :not_active}
  end

  def process_profile(%RecurringProfile{} = profile, today) do
    profile = Repo.preload(profile, :client)

    cond do
      is_nil(profile.next_run_date) ->
        {:skip, :no_schedule}

      Date.compare(profile.next_run_date, today) == :gt ->
        # Already billed for this cycle — most likely by a job that ran while
        # this one was queued behind it.
        {:skip, :not_due}

      is_nil(profile.client) ->
        {:skip, :client_missing}

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
    # In the same transaction as the invoice: if the schedule does not move,
    # the next sweep bills the same profile again, and the customer has two
    # invoices for one month.
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

  # Queued rather than sent: an invoice that is issued but whose mail server is
  # down is a delivery problem, not a reason to roll back the billing.
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
      status: "Draft",
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

  # The stored lines, or a single line standing for the profile itself when it
  # has none. A profile with no items is still a bill for something — its
  # title — and refusing to issue anything would silently stop the billing.
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

  @doc """
  The next billing date after `date` for a frequency.

  Calendar months rather than 30-day steps: billing on the 31st of January
  monthly should land on 28 February and then 31 March, which adding 30 days
  does not do — it drifts, and a "monthly" profile ends up issuing thirteen
  invoices in a year.
  """
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
