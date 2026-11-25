defmodule QuantumBilling.QuotationsFixtures do
  @moduledoc "Quotations for tests, made through the `Quotations` context."

  alias QuantumBilling.Quotations

  def quotation_item_params(over \\ %{}) do
    Map.merge(
      %{
        "description" => "Web Development Services",
        "hsn_sac" => "998313",
        "quantity" => "2",
        "unit" => "Nos",
        "rate" => "25000",
        "tax_rate" => "18",
        "position" => "0"
      },
      over
    )
  end

  def quotation_params(over \\ %{}) do
    today = Quotations.today()

    Map.merge(
      %{
        "quotation_date" => Date.to_iso8601(today),
        "valid_until" => Date.to_iso8601(Date.add(today, 30)),
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "V2V Technologies",
        "items" => %{"0" => quotation_item_params()}
      },
      over
    )
  end

  def quotation_fixture(scope, over \\ %{}) do
    {:ok, quotation} = Quotations.create_quotation(scope, quotation_params(over))
    quotation
  end

  def accepted_quotation_fixture(scope, over \\ %{}) do
    {:ok, quotation} = Quotations.accept(scope, quotation_fixture(scope, over))
    quotation
  end
end
