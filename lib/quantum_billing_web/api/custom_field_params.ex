defmodule QuantumBillingWeb.API.CustomFieldParams do
  @moduledoc """
  The `custom_fields` object an API caller sends. Only fields marked "Include
  in API" are accepted; any other key is refused by name. Money is integer
  minor units of `currency`, like every API amount, and is handed to the
  changeset in major units. Values are then checked by
  `QuantumBilling.CustomFields.cast/5`.
  """

  alias QuantumBilling.Money

  @doc "`{:ok, nil}` when absent, `{:ok, values}`, or `{:error, fields}`."
  def cast(nil, _definitions, _path, _currency), do: {:ok, nil}

  def cast(%{} = values, definitions, path, currency) do
    by_key = Map.new(definitions, &{&1.key, &1})

    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(by_key, key) do
        {:ok, definition} ->
          case value(definition, value, currency) do
            {:ok, value} ->
              {:cont, {:ok, Map.put(acc, key, value)}}

            :error ->
              {:halt, {:error, %{(path <> key) => ["must be a whole number of minor units"]}}}
          end

        :error ->
          {:halt, {:error, %{(path <> key) => ["is not accepted by the API"]}}}
      end
    end)
  end

  def cast(_other, _definitions, path, _currency),
    do: {:error, %{String.trim_trailing(path, ".") => ["must be an object"]}}

  defp value(%{type: "money"}, minor, currency) when is_integer(minor),
    do: {:ok, Money.to_input(minor, currency)}

  defp value(%{type: "money"}, nil, _currency), do: {:ok, nil}
  defp value(%{type: "money"}, _other, _currency), do: :error
  defp value(_definition, value, _currency), do: {:ok, value}
end
