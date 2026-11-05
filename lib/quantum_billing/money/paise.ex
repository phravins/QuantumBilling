defmodule QuantumBilling.Money.Paise do
  @moduledoc """
  An Ecto type for an amount typed in rupees and stored as integer paise (`bigint`).

  Casts `"1,250.50"`, `1250` or a `Decimal` via `Money.parse/1`. Use it only for
  typed input; computed amounts are `:integer` paise set with `put_change/3`.
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
