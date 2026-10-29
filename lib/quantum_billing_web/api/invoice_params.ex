defmodule QuantumBillingWeb.API.InvoiceParams do
  @moduledoc """
  What an API caller may say when creating an invoice — and nothing else.

  `Invoice.changeset/2` casts more than any caller should set, because the
  application itself writes through it: `status`, `irn`, `signed_qr_code`,
  `razorpay_payment_id`, `razorpay_payment_url` and the rest. Passed a request
  body unfiltered, it would let an API caller

    * create an invoice already marked Paid, with an invented payment id;
    * forge an e-invoice registration — an IRN and signed QR the government
      never issued, printed on the document as if it had;
    * point the payment link at any site they like, so that a customer
      clicking *Pay Now* on the real payment page is sent there instead.

  So the body is checked against a short allowlist first, and anything outside
  it is **refused by name** rather than silently dropped. Dropping would let
  the request appear to succeed; refusing shows the integrator exactly which
  field the API will not accept.

  The client is not described here either: `client_id` names a client, and the
  invoice takes that client's name, GSTIN and address from the client record
  (see `QuantumBilling.Invoices.client_snapshot/1`). A body that could set
  `client_gstin` could issue an invoice in one customer's name under another's
  GSTIN. The number and the issuing company come from the server too.
  """

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
            attrs =
              item
              |> Map.take(@item)
              |> Map.new(fn {key, value} -> {key, stringify(value)} end)
              |> Map.put("position", to_string(index))

            {:cont, {:ok, Map.put(acc, to_string(index), attrs)}}

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

  # The changeset casts from strings, as the form sends them.
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp stringify(nil), do: nil
  defp stringify(value), do: value
end
