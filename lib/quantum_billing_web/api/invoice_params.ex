defmodule QuantumBillingWeb.API.InvoiceParams do
  @moduledoc """
  The fields an API caller may set when creating an invoice.

  `Invoice.changeset/2` also casts internal fields (`status`, `irn`, payment
  ids and URLs), so the body is checked against an allowlist and any other
  field is refused by name, not silently dropped. Client details, the number
  and the issuer come from the server (`Invoices.client_snapshot/1`).
  `custom_fields`, on the invoice and on each line, takes the fields marked
  "Include in API".

  The business's regime decides the tax fields: a GST line takes `tax_rate`
  (a slab); a VAT line takes `tax_rate_id` (else the default rate) and the
  invoice `reverse_charge`. The other regime's fields are refused.
  """

  alias QuantumBilling.CustomFields
  alias QuantumBilling.Money
  alias QuantumBillingWeb.API.CustomFieldParams

  @top ~w(client_id invoice_type invoice_date due_date payment_terms place_of_supply
          remarks terms items custom_fields)
  @item ~w(description hsn_sac quantity unit rate custom_fields)
  @max_items 200

  # {regime, invoice fields, line fields} beyond the shared ones.
  @regime_fields %{"gst" => {[], ["tax_rate"]}, "vat" => {["reverse_charge"], ["tax_rate_id"]}}

  @doc """
  `{:ok, client_id, attrs}` with `attrs` shaped for `Invoices.create_invoice/1`
  (less the client snapshot), or `{:error, fields}`. `regime` is the
  business's, `"gst"` or `"vat"`.
  """
  def cast(body, regime \\ "gst")

  def cast(%{} = body, regime) do
    {top_extra, item_extra} = Map.get(@regime_fields, regime, @regime_fields["gst"])
    top = @top ++ top_extra

    with :ok <- refuse_unknown(body, top, "", regime),
         {:ok, client_id} <- client_id(body["client_id"]),
         {:ok, custom} <- custom_fields(body["custom_fields"], "invoice", "custom_fields."),
         {:ok, items} <- items(body["items"], @item ++ item_extra, regime) do
      attrs =
        body
        |> Map.take(top -- ["client_id", "items", "custom_fields"])
        |> Map.new(fn {key, value} -> {key, stringify(value)} end)
        |> Map.put("items", items)
        |> put_custom(custom)

      {:ok, client_id, attrs}
    end
  end

  def cast(_body, _regime), do: {:error, %{"body" => ["must be a JSON object"]}}

  defp refuse_unknown(map, allowed, path, regime) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] ->
        :ok

      unknown ->
        {:error, Map.new(unknown, &{path <> &1, [refusal(&1, regime)]})}
    end
  end

  defp refusal(field, "gst") when field in ["reverse_charge", "tax_rate_id"],
    do: "is for VAT invoices; this business charges GST"

  defp refusal("tax_rate", "vat"),
    do: "is for GST invoices; a VAT line takes tax_rate_id"

  defp refusal(_field, _regime), do: "is not accepted by the API"

  defp client_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp client_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      _other -> {:error, %{"client_id" => ["must be the id of an existing client"]}}
    end
  end

  defp client_id(_id), do: {:error, %{"client_id" => ["is required"]}}

  defp custom_fields(nil, _object, _path), do: {:ok, nil}

  defp custom_fields(values, object, path),
    do: CustomFieldParams.cast(values, CustomFields.api_definitions(object), path)

  defp put_custom(attrs, nil), do: attrs
  defp put_custom(attrs, custom), do: Map.put(attrs, "custom_fields", custom)

  defp items(items, allowed, regime)
       when is_list(items) and items != [] and length(items) <= @max_items do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn
      {%{} = item, index}, {:ok, acc} ->
        path = "items.#{index}."

        with :ok <- refuse_unknown(item, allowed, path, regime),
             {:ok, rate} <- rate(item["rate"], index),
             {:ok, custom} <-
               custom_fields(item["custom_fields"], "invoice_item", path <> "custom_fields.") do
          attrs =
            item
            |> Map.take(allowed -- ["custom_fields"])
            |> Map.new(fn {key, value} -> {key, stringify(value)} end)
            |> put_rate(rate)
            |> put_custom(custom)
            |> Map.put("position", to_string(index))

          {:cont, {:ok, Map.put(acc, to_string(index), attrs)}}
        else
          {:error, _fields} = error -> {:halt, error}
        end

      {_not_a_map, index}, _acc ->
        {:halt, {:error, %{"items.#{index}" => ["must be an object"]}}}
    end)
  end

  defp items(items, _allowed, _regime) when is_list(items) and length(items) > @max_items,
    do: {:error, %{"items" => ["can contain at most #{@max_items} lines"]}}

  defp items(_items, _allowed, _regime),
    do: {:error, %{"items" => ["must be a non-empty list of lines"]}}

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
