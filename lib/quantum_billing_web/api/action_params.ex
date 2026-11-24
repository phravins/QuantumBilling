defmodule QuantumBillingWeb.API.ActionParams do
  @moduledoc """
  Bodies of the API's action endpoints — record a payment, cancel, raise a
  credit note — checked against what each accepts, with unknown fields refused
  by name, as `QuantumBillingWeb.API.InvoiceParams` does for creation.
  """

  alias QuantumBilling.Money

  @doc "`%{\"reference\" => text, \"amount\" => paise}`."
  def payment(%{} = body) do
    with :ok <- only(body, ~w(reference amount)),
         {:ok, reference} <- text(body, "reference", 100),
         {:ok, amount} <- paise(body, "amount", required: true) do
      {:ok, reference, amount}
    end
  end

  def payment(_body), do: {:error, %{"body" => ["must be a JSON object"]}}

  @doc "`%{\"reason\" => text}`."
  def cancellation(%{} = body) do
    with :ok <- only(body, ~w(reason)), {:ok, reason} <- text(body, "reason", 200) do
      {:ok, reason}
    end
  end

  def cancellation(_body), do: {:error, %{"body" => ["must be a JSON object"]}}

  @doc "An empty object: the e-invoice action takes nothing."
  def empty(%{} = body) do
    with :ok <- only(body, []), do: :ok
  end

  def empty(_body), do: {:error, %{"body" => ["must be a JSON object"]}}

  @doc """
  Emailing a quotation: `%{"to" => address}`, or `{:ok, nil}` with no `to`,
  for the quotation's own client email.
  """
  def quotation_email(%{} = body) do
    with :ok <- only(body, ~w(to)) do
      if Map.has_key?(body, "to"), do: text(body, "to", 160), else: {:ok, nil}
    end
  end

  def quotation_email(_body), do: {:error, %{"body" => ["must be a JSON object"]}}

  @doc """
  A credit or debit note: `type` ("credit" or "debit"), `reason`, and the
  amounts in minor units of the invoice's `currency`. A total left out
  defaults to what can still be credited (for a debit note, the invoice's
  total), and a taxable value or tax left out is taken from the total in the
  invoice's proportion, as in the application. A credit note over what can
  still be credited is refused. Returns attrs for
  `CreditNotes.create_credit_note_for_invoice/2`, whose amounts are major units.
  """
  def credit_note(%{} = body, currency) do
    with :ok <- only(body, ~w(type reason subtotal tax_total grand_total)),
         {:ok, type} <- note_type(body["type"]),
         {:ok, reason} <- text(body, "reason", 200),
         {:ok, subtotal} <- paise(body, "subtotal", required: false),
         {:ok, tax_total} <- paise(body, "tax_total", required: false),
         {:ok, grand_total} <- paise(body, "grand_total", required: false) do
      attrs =
        %{"note_type" => type, "reason" => reason}
        |> put_major("subtotal", subtotal, currency)
        |> put_major("tax_total", tax_total, currency)
        |> put_major("grand_total", grand_total, currency)

      {:ok, attrs}
    end
  end

  def credit_note(_body, _currency), do: {:error, %{"body" => ["must be a JSON object"]}}

  defp only(body, allowed) do
    case body |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] -> :ok
      unknown -> {:error, Map.new(unknown, &{&1, ["is not accepted by the API"]})}
    end
  end

  defp text(body, field, max) do
    case body[field] do
      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" ->
            {:error, %{field => ["can't be blank"]}}

          String.length(value) > max ->
            {:error, %{field => ["must be at most #{max} characters"]}}

          not String.printable?(value) ->
            {:error, %{field => ["must be printable text"]}}

          true ->
            {:ok, value}
        end

      nil ->
        {:error, %{field => ["is required"]}}

      _other ->
        {:error, %{field => ["must be a string"]}}
    end
  end

  defp paise(body, field, required: required?) do
    case body[field] do
      nil when required? -> {:error, %{field => ["is required"]}}
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, %{field => ["must be a whole number of minor units, 0 or more"]}}
    end
  end

  defp note_type("credit"), do: {:ok, "Credit"}
  defp note_type("debit"), do: {:ok, "Debit"}
  defp note_type(_other), do: {:error, %{"type" => ["must be \"credit\" or \"debit\""]}}

  defp put_major(attrs, _field, nil, _currency), do: attrs

  defp put_major(attrs, field, minor, currency),
    do: Map.put(attrs, field, Money.to_input(minor, currency))
end
