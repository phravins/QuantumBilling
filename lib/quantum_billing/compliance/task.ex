defmodule QuantumBilling.Compliance.Task do
  @moduledoc """
  A task added by hand to the Compliance page (statutory returns are generated, not stored).

  `kind`, `status` and `created_by_id` are set in code, never from a form.

    * `category` `"custom"` with `custom_category` - the person's own label, also a filter tab
    * `repeat` - completing it adds the next one (`Compliance.complete_task/2`)
    * `private` - visible to its author only
    * `remind_at` - time of day in the organisation's timezone; nil means morning
    * `email_reminder` - also email the author
  """
  use Ecto.Schema

  import Ecto.Changeset

  @categories ~w(returns payments other custom)
  @repeats ~w(none weekly monthly quarterly yearly)
  @castable ~w(title notes category custom_category due_date remind_days_before
               repeat private remind_at email_reminder)a

  # A browser date input accepts year 0001, which no calendar will take.
  @earliest ~D[2000-01-01]
  @latest ~D[2100-12-31]

  schema "compliance_tasks" do
    field :title, :string
    field :notes, :string
    field :category, :string, default: "other"
    field :due_date, :date
    field :kind, :string, default: "task"
    field :status, :string, default: "open"
    field :completed_at, :utc_datetime
    field :remind_days_before, :integer, default: 1
    field :reminded_at, :utc_datetime
    field :custom_category, :string
    field :repeat, :string, default: "none"
    field :private, :boolean, default: false
    field :remind_at, :time
    field :email_reminder, :boolean, default: false

    belongs_to :created_by, QuantumBilling.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(%__MODULE__{} = task, attrs) do
    task
    |> cast(attrs, @castable)
    |> update_change(:title, &trim/1)
    |> update_change(:notes, &trim/1)
    |> update_change(:custom_category, &trim/1)
    |> validate_required([:title, :category, :due_date, :remind_days_before, :repeat])
    |> validate_length(:title, max: 200)
    |> validate_length(:notes, max: 2000)
    |> validate_inclusion(:category, @categories)
    |> validate_custom_category()
    |> validate_inclusion(:repeat, @repeats)
    |> validate_number(:remind_days_before,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 365
    )
    |> validate_change(:due_date, &validate_due_date/2)
    |> reset_reminder()
  end

  # A custom category needs its name; any other drops a stale one.
  defp validate_custom_category(changeset) do
    if get_field(changeset, :category) == "custom" do
      changeset
      |> validate_required(:custom_category, message: "give the category a name")
      |> validate_length(:custom_category, max: 40)
    else
      put_change(changeset, :custom_category, nil)
    end
  end

  @doc "How often a task can repeat."
  def repeats, do: @repeats

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp validate_due_date(field, date) do
    if Date.compare(date, @earliest) == :lt or Date.compare(date, @latest) == :gt do
      [{field, "must be between 2000 and 2100"}]
    else
      []
    end
  end

  # A new date, lead time or hour is a new reminder.
  defp reset_reminder(changeset) do
    if changed?(changeset, :due_date) or changed?(changeset, :remind_days_before) or
         changed?(changeset, :remind_at) do
      put_change(changeset, :reminded_at, nil)
    else
      changeset
    end
  end
end
