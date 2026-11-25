defmodule QuantumBillingWeb.API.V1.ClientJSON do
  @moduledoc """
  A client as the API shows it, field by field. Not exposed: `notes`,
  `opening_balance`, `outstanding`, `credit_limit` and `deleted_at`.
  `custom_fields` holds only the fields marked "Include in API"; a money one
  is integer minor units of `currency`, the business currency, which has
  `currency_exponent` decimal places.
  """

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Currency
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Settings

  @fields ~w(id type name display_name legal_name gstin pan tax_number country business_type
             category email phone billing_address shipping_address payment_terms_days status
             currency currency_exponent custom_fields created_at updated_at)a

  @doc "The fields of a client, for the test that pins them."
  def fields, do: @fields

  def index(%{page: page}) do
    context = context()

    %{
      data: Enum.map(page.rows, &client(&1, context)),
      meta: QuantumBillingWeb.API.Pagination.meta(page)
    }
  end

  def show(%{client: client}), do: %{data: client(client, context())}

  # Read once per response, not once per client.
  defp context,
    do: %{definitions: CustomFields.api_definitions("client"), currency: Settings.currency_code()}

  defp client(%Client{} = client, %{definitions: definitions, currency: currency}) do
    billing = %{
      line1: client.billing_line1,
      line2: client.billing_line2,
      city: client.billing_city,
      state: client.billing_state,
      pin: client.billing_pin
    }

    %{
      id: client.id,
      type: client.client_type,
      name: client.name,
      display_name: client.display_name,
      legal_name: client.legal_name,
      gstin: client.gstin,
      pan: client.pan,
      tax_number: client.tax_number,
      country: client.country,
      business_type: client.business_type,
      category: client.category,
      email: client.email,
      phone: phone(client),
      billing_address: billing,
      shipping_address:
        if(client.shipping_same_as_billing,
          do: billing,
          else: %{
            line1: client.shipping_line1,
            line2: client.shipping_line2,
            city: client.shipping_city,
            state: client.shipping_state,
            pin: client.shipping_pin
          }
        ),
      payment_terms_days: client.payment_terms_days,
      status: client.status,
      currency: currency,
      currency_exponent: Currency.exponent(currency),
      custom_fields: CustomFields.visible_values(client.custom_fields, definitions),
      created_at: client.inserted_at,
      updated_at: client.updated_at
    }
  end

  defp phone(%Client{phone: phone}) when phone in [nil, ""], do: nil
  defp phone(%Client{phone_country_code: code, phone: phone}), do: "#{code}#{phone}"
end
