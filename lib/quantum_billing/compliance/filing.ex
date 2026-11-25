defmodule QuantumBilling.Compliance.Filing do
  @moduledoc """
  A GST return the business has marked as filed.

  Obligations are generated, not stored (see `QuantumBilling.Compliance`), so a
  filing names its obligation by `type` and `period_key` (`MMYYYY`), unique
  together. `type`, `period_key` and `user_id` are set in code, never from a
  form; the form gives the date, the ARN and a note.
  """
  use Ecto.Schema

  import Ecto.Changeset

  # GST came into force on 1 July 2017; nothing was filed before it.
  @earliest ~D[2017-07-01]

  schema "compliance_filings" do
    field :type, :string
    field :period_key, :string
    field :filed_on, :date
    field :arn, :string
    field :note, :string

    belongs_to :user, QuantumBilling.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts the date, ARN and note. `today` is the business's local date: a return
  cannot have been filed after it.
  """
  def changeset(%__MODULE__{} = filing, attrs, %Date{} = today) do
    filing
    |> cast(attrs, [:filed_on, :arn, :note])
    |> update_change(:arn, &normalize_arn/1)
    |> update_change(:note, &trim/1)
    |> validate_required([:filed_on], message: "enter the date it was filed")
    |> validate_change(:filed_on, &validate_filed_on(&1, &2, today))
    |> validate_format(:arn, ~r/^[A-Z0-9]{15}$/,
      message: "should be the 15-character ARN from the GST portal"
    )
    |> validate_length(:note, max: 500)
    # On the date, the one field of the form that shows it: two people marking
    # the same return at once.
    |> unique_constraint([:type, :period_key],
      error_key: :filed_on,
      message: "this return is already marked as filed"
    )
  end

  defp validate_filed_on(field, date, today) do
    cond do
      Date.after?(date, today) -> [{field, "can't be in the future"}]
      Date.before?(date, @earliest) -> [{field, "is before GST began"}]
      true -> []
    end
  end

  # The portal shows ARNs in capitals; people paste them with spaces.
  defp normalize_arn(arn) when is_binary(arn) do
    arn |> String.replace(~r/\s+/, "") |> String.upcase()
  end

  defp normalize_arn(arn), do: arn

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
