defmodule QuantumBillingWeb.API.InvoiceParams do
  @moduledoc """
  The fields an API caller may set when creating an invoice.

  `Invoice.changeset/2` also casts internal fields (`status`, `irn`, payment
  ids and URLs), so the body is checked against an allowlist and any other
  field is refused by name, not silently dropped. Client details, the number
  and the issuer come from the server (`Invoices.client_snapshot/1`).
  """

  alias QuantumBilling.Money

  @top ~w(client_id invoice_type invoice_date due_date payment_terms place_of_supply
          remarks terms items)
  @item ~w(description hsn_sac quantity unit rate tax_rate)
  @max_items 200

  @doc """
  `{:ok, client_id, attrs}` with `attrs` shaped for `Invoices.create_invoice/1`
  (less the client snapshot), or `{:error, fields}`.
  """
  def cast(%{} = body) do
    with :ok <- refuse_unknown(body, @top, ""),
         {:ok, client_id} <- client_id(body["client_id"]),
         {:ok, items} <- items(body["items"]) do
      attrs =
        body
        |> Map.take(@top -- ["client_id", "items"])
        |> Map.new(fn {key, value} -> {key, stringify(value)} end)
        |> Map.put("items", items)

      {:ok, client_id, attrs}
    end
  end

  def cast(_body), do: {:error, %{"body" => ["must be a JSON object"]}}

  defp refuse_unknown(map, allowed, path) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] ->
        :ok

      unknown ->
        {:error, Map.new(unknown, &{path <> &1, ["is not accepted by the API"]})}
    end
  end

  defp client_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp client_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      _other -> {:error, %{"client_id" => ["must be the id of an existing client"]}}
    end
  end

  defp client_id(_id), do: {:error, %{"client_id" => ["is required"]}}

  defp items(items) when is_list(items) and items != [] and length(items) <= @max_items do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn
      {%{} = item, index}, {:ok, acc} ->
        case refuse_unknown(item, @item, "items.#{index}.") do
          :ok ->
            case rate(item["rate"], index) do
              {:ok, rate} ->
                attrs =
                  item
                  |> Map.take(@item)
                  |> Map.new(fn {key, value} -> {key, stringify(value)} end)
                  |> put_rate(rate)
                  |> Map.put("position", to_string(index))

                {:cont, {:ok, Map.put(acc, to_string(index), attrs)}}

              {:error, _fields} = error ->
                {:halt, error}
            end

          {:error, _fields} = error ->
            {:halt, error}
        end

      {_not_a_map, index}, _acc ->
        {:halt, {:error, %{"items.#{index}" => ["must be an object"]}}}
    end)
  end

  defp items(items) when is_list(items) and length(items) > @max_items,
    do: {:error, %{"items" => ["can contain at most #{@max_items} lines"]}}

  defp items(_items), do: {:error, %{"items" => ["must be a non-empty list of lines"]}}

  # API amounts are integer paise; the changeset expects rupees, so 125050 becomes "1250.50".
  defp rate(nil, _index), do: {:ok, nil}
  defp rate(paise, _index) when is_integer(paise) and paise >= 0, do: {:ok, Money.to_input(paise)}

  defp rate(_other, index),
    do: {:error, %{"items.#{index}.rate" => ["must be a whole number of paise, 0 or more"]}}

  defp put_rate(attrs, nil), do: attrs
  defp put_rate(attrs, rupees), do: Map.put(attrs, "rate", rupees)

  # The changeset casts from strings, as the form sends them.
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp stringify(nil), do: nil
  defp stringify(value), do: value
end
