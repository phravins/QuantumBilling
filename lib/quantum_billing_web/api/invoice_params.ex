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

  Amounts (`rate`, money custom fields) are integer minor units of the
  business currency, the one the document will bill in: 100 to the unit, or
  1000 for KWD, BHD and OMR.
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
  business's, `"gst"` or `"vat"`, and `currency` its ISO code.
  """
  def cast(body, regime, currency),
    do:
      cast_document(body, regime, %{
        top: @top,
        object: "invoice",
        item_object: "invoice_item",
        currency: currency
      })

  @doc """
  `cast/3` for another document with invoice-style lines (a quotation):
  `spec` names its allowed top-level fields (`:top`, with `client_id`,
  `items` and `custom_fields`), its custom-field objects (`:object`,
  `:item_object`) and the `:currency` its amounts are in.
  """
  def cast_document(
        %{} = body,
        regime,
        %{top: top, object: object, item_object: item_object, currency: currency}
      ) do
    {top_extra, item_extra} = Map.get(@regime_fields, regime, @regime_fields["gst"])
    top = top ++ top_extra

    lines = %{
      allowed: @item ++ item_extra,
      regime: regime,
      object: item_object,
      currency: currency
    }

    with :ok <- refuse_unknown(body, top, "", regime),
         {:ok, client_id} <- client_id(body["client_id"]),
         {:ok, custom} <-
           custom_fields(body["custom_fields"], object, "custom_fields.", currency),
         {:ok, items} <- items(body["items"], lines) do
      attrs =
        body
        |> Map.take(top -- ["client_id", "items", "custom_fields"])
        |> Map.new(fn {key, value} -> {key, stringify(value)} end)
        |> Map.put("items", items)
        |> put_custom(custom)

      {:ok, client_id, attrs}
    end
  end

  def cast_document(_body, _regime, _spec), do: {:error, %{"body" => ["must be a JSON object"]}}

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

  defp custom_fields(nil, _object, _path, _currency), do: {:ok, nil}

  defp custom_fields(values, object, path, currency),
    do: CustomFieldParams.cast(values, CustomFields.api_definitions(object), path, currency)

  defp put_custom(attrs, nil), do: attrs
  defp put_custom(attrs, custom), do: Map.put(attrs, "custom_fields", custom)

  defp items(items, %{allowed: allowed, regime: regime, object: item_object, currency: currency})
       when is_list(items) and items != [] and length(items) <= @max_items do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn
      {%{} = item, index}, {:ok, acc} ->
        path = "items.#{index}."

        with :ok <- refuse_unknown(item, allowed, path, regime),
             {:ok, rate} <- rate(item["rate"], index, currency),
             {:ok, custom} <-
               custom_fields(
                 item["custom_fields"],
                 item_object,
                 path <> "custom_fields.",
                 currency
               ) do
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

  defp items(items, _lines) when is_list(items) and length(items) > @max_items,
    do: {:error, %{"items" => ["can contain at most #{@max_items} lines"]}}

  defp items(_items, _lines),
    do: {:error, %{"items" => ["must be a non-empty list of lines"]}}

  # API amounts are integer minor units; the changeset reads major units, so
  # 125050 becomes "1250.50" in INR and "125.050" in KWD.
  defp rate(nil, _index, _currency), do: {:ok, nil}

  defp rate(minor, _index, currency) when is_integer(minor) and minor >= 0,
    do: {:ok, Money.to_input(minor, currency)}

  defp rate(_other, index, _currency),
    do: {:error, %{"items.#{index}.rate" => ["must be a whole number of minor units, 0 or more"]}}

  defp put_rate(attrs, nil), do: attrs
  defp put_rate(attrs, major), do: Map.put(attrs, "rate", major)

  # The changeset casts from strings, as the form sends them.
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp stringify(nil), do: nil
  defp stringify(value), do: value
end
