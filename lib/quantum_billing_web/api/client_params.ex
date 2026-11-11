defmodule QuantumBillingWeb.API.ClientParams do
  @moduledoc """
  The fields an API caller may set when creating a client (the shape the API
  returns). Unknown fields are refused by name. `status`, `notes`,
  `credit_limit`, `opening_balance` and `outstanding` are not settable.
  `custom_fields` takes the fields marked "Include in API". `tax_number` and
  `country` (ISO-2) are the VAT identity, checked by `Client.changeset/3`.
  """

  alias QuantumBilling.CustomFields
  alias QuantumBillingWeb.API.CustomFieldParams

  @top ~w(type name display_name legal_name gstin pan tax_number country business_type
          category email phone phone_country_code billing_address shipping_address
          payment_terms_days custom_fields)
  @address ~w(line1 line2 city state pin)

  @doc "`{:ok, attrs}` shaped for `Clients.create_client/1`, or `{:error, fields}`."
  def cast(%{} = body) do
    with :ok <- refuse_unknown(body, @top, ""),
         {:ok, billing} <- address(body["billing_address"], "billing_address", required: true),
         {:ok, shipping} <-
           address(body["shipping_address"], "shipping_address", required: false),
         {:ok, custom} <- custom_fields(body["custom_fields"]) do
      attrs =
        %{
          "client_type" => body["type"],
          "name" => body["name"],
          "display_name" => body["display_name"],
          "legal_name" => body["legal_name"],
          "gstin" => body["gstin"],
          "pan" => body["pan"],
          "tax_number" => body["tax_number"],
          "country" => body["country"],
          "business_type" => body["business_type"],
          "category" => body["category"],
          "email" => body["email"],
          "phone" => body["phone"],
          "phone_country_code" => body["phone_country_code"],
          "payment_terms_days" => body["payment_terms_days"]
        }
        |> Map.merge(prefixed(billing, "billing_"))
        |> Map.merge(shipping_attrs(shipping))
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(fn {key, value} -> {key, stringify(value)} end)
        |> put_custom(custom)

      {:ok, attrs}
    end
  end

  def cast(_body), do: {:error, %{"body" => ["must be a JSON object"]}}

  defp custom_fields(nil), do: {:ok, nil}

  defp custom_fields(values),
    do: CustomFieldParams.cast(values, CustomFields.api_definitions("client"), "custom_fields.")

  defp put_custom(attrs, nil), do: attrs
  defp put_custom(attrs, custom), do: Map.put(attrs, "custom_fields", custom)

  defp shipping_attrs(nil), do: %{"shipping_same_as_billing" => "true"}

  defp shipping_attrs(shipping),
    do: shipping |> prefixed("shipping_") |> Map.put("shipping_same_as_billing", "false")

  defp address(nil, field, required: true), do: {:error, %{field => ["is required"]}}
  defp address(nil, _field, required: false), do: {:ok, nil}

  defp address(%{} = address, field, _opts) do
    with :ok <- refuse_unknown(address, @address, field <> ".") do
      {:ok, Map.take(address, @address)}
    end
  end

  defp address(_other, field, _opts), do: {:error, %{field => ["must be an object"]}}

  defp prefixed(address, prefix),
    do: Map.new(address, fn {key, value} -> {prefix <> key, value} end)

  defp refuse_unknown(map, allowed, path) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] -> :ok
      unknown -> {:error, Map.new(unknown, &{path <> &1, ["is not accepted by the API"]})}
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: to_string(value)
  defp stringify(value), do: value
end
