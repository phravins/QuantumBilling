defmodule QuantumBilling.TaxRates.TaxRate do
  @moduledoc """
  One VAT rate, such as "Standard 5%". `rate_bp` is basis points (750 is
  7.5%); the form takes a percentage in `percent`. Zero-rated, exempt,
  reverse-charge and out-of-scope rates are always 0%.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias QuantumBilling.Tax

  schema "tax_rates" do
    field :name, :string
    field :category, :string, default: "standard"
    field :rate_bp, :integer, default: 0
    field :percent, :string, virtual: true
    field :exemption_reason, :string
    field :is_default, :boolean, default: false
    field :position, :integer, default: 0
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(%__MODULE__{} = rate, attrs) do
    rate
    |> cast(attrs, [:name, :category, :percent, :exemption_reason])
    |> update_change(:name, &String.trim/1)
    |> update_change(:exemption_reason, &String.trim/1)
    |> validate_required([:name, :category])
    |> validate_length(:name, max: 60)
    |> validate_length(:exemption_reason, max: 200)
    |> validate_inclusion(:category, Tax.category_codes())
    |> put_rate()
  end

  # Untaxed categories are 0%, whatever was typed.
  defp put_rate(changeset) do
    category = get_field(changeset, :category)

    cond do
      Tax.untaxed_category?(category) ->
        changeset |> put_change(:rate_bp, 0) |> delete_change(:percent)

      percent = get_change(changeset, :percent) ->
        case Tax.parse_percent(percent) do
          {:ok, bp} when bp > 0 and bp <= 10_000 ->
            put_change(changeset, :rate_bp, bp)

          _invalid ->
            add_error(changeset, :percent, "must be a percentage above 0, like 5 or 7.5")
        end

      (get_field(changeset, :rate_bp) || 0) <= 0 ->
        add_error(
          changeset,
          :percent,
          "can't be blank for a #{Tax.category_label(category)} rate"
        )

      true ->
        changeset
    end
  end

  @doc "The form's view of a stored rate: its percentage filled in."
  def with_percent(%__MODULE__{} = rate), do: %{rate | percent: Tax.percent(rate.rate_bp)}

  @doc "How a rate reads in a picker: \"Standard 5% · 5%\" is shortened to \"Standard 5%\"."
  def label(%__MODULE__{name: name, rate_bp: rate_bp, category: category}) do
    percent = Tax.percent_label(rate_bp)

    cond do
      Tax.untaxed_category?(category) -> name
      String.contains?(name, percent) -> name
      true -> "#{name} (#{percent})"
    end
  end
end
