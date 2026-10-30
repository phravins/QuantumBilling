defmodule QuantumBillingWeb.API.V1.ClientJSON do
  @moduledoc """
  A client as the API shows it, field by field.

  Not exposed: `notes`, which are free text the business writes about its own
  customer and has no reason to expect leaving the application; and
  `opening_balance`, `outstanding` and `credit_limit`, which are the business's
  view of what a customer owes and how far it trusts them — financial
  judgement, not master data. `deleted_at` is internal; a binned client is not
  returned at all.
  """

  alias QuantumBilling.Clients.Client

  @fields ~w(id type name display_name legal_name gstin pan business_type category
             email phone billing_address shipping_address payment_terms_days status
             created_at updated_at)a

  @doc "The fields of a client, for the test that pins them."
  def fields, do: @fields

  def index(%{page: page}) do
    %{
      data: Enum.map(page.rows, &client/1),
      meta: QuantumBillingWeb.API.Pagination.meta(page)
    }
  end

  def show(%{client: client}), do: %{data: client(client)}

  defp client(%Client{} = client) do
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
      created_at: client.inserted_at,
      updated_at: client.updated_at
    }
  end

  defp phone(%Client{phone: phone}) when phone in [nil, ""], do: nil
  defp phone(%Client{phone_country_code: code, phone: phone}), do: "#{code}#{phone}"
end
