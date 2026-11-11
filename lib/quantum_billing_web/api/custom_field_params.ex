defmodule QuantumBillingWeb.API.CustomFieldParams do
  @moduledoc """
  The `custom_fields` object an API caller sends. Only fields marked "Include
  in API" are accepted; any other key is refused by name. Money is integer
  paise, like every API amount, and is handed to the changeset as rupees.
  Values are then checked by `QuantumBilling.CustomFields.cast/4`.
  """

  alias QuantumBilling.Money

  @doc "`{:ok, nil}` when absent, `{:ok, values}`, or `{:error, fields}`."
  def cast(nil, _definitions, _path), do: {:ok, nil}

  def cast(%{} = values, definitions, path) do
    by_key = Map.new(definitions, &{&1.key, &1})

    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(by_key, key) do
        {:ok, definition} ->
          case value(definition, value) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            :error -> {:halt, {:error, %{(path <> key) => ["must be a whole number of paise"]}}}
          end

        :error ->
          {:halt, {:error, %{(path <> key) => ["is not accepted by the API"]}}}
      end
    end)
  end

  def cast(_other, _definitions, path),
    do: {:error, %{String.trim_trailing(path, ".") => ["must be an object"]}}

  defp value(%{type: "money"}, paise) when is_integer(paise), do: {:ok, Money.to_input(paise)}
  defp value(%{type: "money"}, nil), do: {:ok, nil}
  defp value(%{type: "money"}, _other), do: :error
  defp value(_definition, value), do: {:ok, value}
end
