defmodule QuantumBilling.Compliance.Task do
  @moduledoc """
  Something a person added to the Compliance page by hand.

  Statutory returns are generated from the rules and never stored, so anything
  they do not cover, such as a licence renewal or a note to chase the accountant,
  lives here instead.

  `kind`, `status` and `created_by_id` are set in code, never taken from a form.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @categories ~w(returns payments other)
  @castable ~w(title notes category due_date remind_days_before)a

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

    belongs_to :created_by, QuantumBilling.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(%__MODULE__{} = task, attrs) do
    task
    |> cast(attrs, @castable)
    |> update_change(:title, &trim/1)
    |> update_change(:notes, &trim/1)
    |> validate_required([:title, :category, :due_date, :remind_days_before])
    |> validate_length(:title, max: 200)
    |> validate_length(:notes, max: 2000)
    |> validate_inclusion(:category, @categories)
    |> validate_number(:remind_days_before,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 365
    )
    |> validate_change(:due_date, &validate_due_date/2)
    |> reset_reminder()
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp validate_due_date(field, date) do
    if Date.compare(date, @earliest) == :lt or Date.compare(date, @latest) == :gt do
      [{field, "must be between 2000 and 2100"}]
    else
      []
    end
  end

  # A new date or lead time is a new reminder.
  defp reset_reminder(changeset) do
    if changed?(changeset, :due_date) or changed?(changeset, :remind_days_before) do
      put_change(changeset, :reminded_at, nil)
    else
      changeset
    end
  end
end
