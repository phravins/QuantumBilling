defmodule QuantumBilling.Money.Paise do
  @moduledoc """
  An Ecto type for an amount typed in rupees and held in paise.

  Casting reads rupees — `"1,250.50"`, `1250`, `Decimal.new("1250.5")` — the
  way a form, a recurring profile's stored lines or an import supplies them,
  and turns them into paise with `QuantumBilling.Money.parse/1`. Loading and
  dumping are plain integers, so the column is an ordinary `bigint`.

  Use it only on fields cast from what a person typed. Amounts the
  application works out itself (totals, tax) are `:integer` paise set with
  `put_change/3`, and never pass through a rupee reading.
  """
  use Ecto.Type

  alias QuantumBilling.Money

  @impl true
  def type, do: :integer

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast(rupees) do
    case Money.parse(rupees) do
      {:ok, paise} -> {:ok, paise}
      :error -> {:error, message: "must be an amount with at most two decimal places"}
    end
  end

  @impl true
  def load(paise) when is_integer(paise), do: {:ok, paise}
  def load(_value), do: :error

  @impl true
  def dump(paise) when is_integer(paise), do: {:ok, paise}
  def dump(_value), do: :error
end
