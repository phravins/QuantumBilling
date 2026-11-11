defmodule QuantumBillingWeb.ClientExportController do
  @moduledoc """
  The Clients list as CSV, with the on-screen search, status and custom-field
  filters from the query string.

  Headers are the client import's own labels, so an exported file maps itself
  when it is imported, here or into another business. Not chunked: a client
  list stays small next to the invoice register.
  """
  use QuantumBillingWeb, :controller

  plug QuantumBillingWeb.Plugs.RecordExport, "client export" when action in [:export]

  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Money
  alias QuantumBillingWeb.CSV
  alias QuantumBillingWeb.CustomFieldComponents

  def export(conn, params) do
    regime = conn.assigns.current_scope.tax_regime
    definitions = CustomFields.active_definitions("client")
    columns = columns(regime)

    clients =
      Clients.export_rows(
        search: param(params, "q", ""),
        status: param(params, "status", "All Status"),
        custom: custom_filters(params)
      )

    headers =
      Enum.map(columns, &elem(&1, 0)) ++ CustomFieldComponents.export_headers(definitions)

    rows =
      Enum.map(clients, fn client ->
        Enum.map(columns, fn {_header, value} -> to_string(value.(client)) end) ++
          CustomFieldComponents.export_cells(definitions, client.custom_fields)
      end)

    send_download(conn, {:binary, Enum.map_join([headers | rows], &CSV.line/1)},
      filename: "clients.csv",
      content_type: "text/csv"
    )
  end

  defp param(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing_or_nested -> default
    end
  end

  # Keys that aren't filterable fields, and values that don't cast, are
  # dropped later by `CustomFields.filter_where/3`.
  defp custom_filters(%{"custom" => filters}) when is_map(filters) do
    Map.filter(filters, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp custom_filters(_params), do: %{}

  defp columns(regime) do
    postal = if regime == "vat", do: "Postal code", else: "PIN code"

    [
      {"Client name", & &1.name},
      {"Display name", & &1.display_name},
      {"Legal name", & &1.legal_name},
      {"Client type", & &1.client_type}
    ] ++
      tax_columns(regime) ++
      [
        {"Country", & &1.country},
        {"Email", & &1.email},
        {"Phone country code", & &1.phone_country_code},
        {"Phone", & &1.phone},
        {"Address line 1", & &1.billing_line1},
        {"Address line 2", & &1.billing_line2},
        {"City", & &1.billing_city},
        {"State", & &1.billing_state},
        {postal, & &1.billing_pin},
        {"Shipping address line 1", &shipping(&1).line1},
        {"Shipping address line 2", &shipping(&1).line2},
        {"Shipping city", &shipping(&1).city},
        {"Shipping state", &shipping(&1).state},
        {"Shipping #{String.downcase(postal)}", &shipping(&1).pin},
        {"Business type", & &1.business_type},
        {"Category", & &1.category},
        {"Payment terms (days)", & &1.payment_terms_days},
        {"Credit limit", &amount(&1.credit_limit)},
        {"Opening balance", &amount(&1.opening_balance)},
        {"Outstanding", &amount(&1.outstanding)},
        {"Status", & &1.status},
        {"Notes", & &1.notes}
      ]
  end

  defp tax_columns("vat"), do: [{"Tax number", & &1.tax_number}]
  defp tax_columns(_gst), do: [{"GSTIN", & &1.gstin}, {"PAN", & &1.pan}]

  # The address goods go to: the billing one when the client ships there.
  defp shipping(%Client{shipping_same_as_billing: true} = client) do
    %{
      line1: client.billing_line1,
      line2: client.billing_line2,
      city: client.billing_city,
      state: client.billing_state,
      pin: client.billing_pin
    }
  end

  defp shipping(%Client{} = client) do
    %{
      line1: client.shipping_line1,
      line2: client.shipping_line2,
      city: client.shipping_city,
      state: client.shipping_state,
      pin: client.shipping_pin
    }
  end

  # Plain numbers, from paise, so a spreadsheet can sum them.
  defp amount(nil), do: ""
  defp amount(paise), do: Money.to_input(paise)
end
