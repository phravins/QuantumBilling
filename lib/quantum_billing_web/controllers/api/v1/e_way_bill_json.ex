defmodule QuantumBillingWeb.API.V1.EWayBillJSON do
  @moduledoc """
  An e-way bill as the API shows it, field by field. It references its invoice
  by id and number only; the invoice itself needs `invoices:read`.
  """

  alias QuantumBilling.EWayBills.EWayBill

  @fields ~w(id number date valid_until status distance_km mode_of_transport
             vehicle_number transporter_id transporter_name cancelled_at
             cancellation_reason invoice created_at updated_at)a

  @doc "The fields of an e-way bill, for the test that pins them."
  def fields, do: @fields

  def index(%{page: page}) do
    %{
      data: Enum.map(page.rows, &bill/1),
      meta: QuantumBillingWeb.API.Pagination.meta(page)
    }
  end

  def show(%{bill: bill}), do: %{data: bill(bill)}

  defp bill(%EWayBill{} = bill) do
    %{
      id: bill.id,
      number: bill.ewb_number,
      date: bill.ewb_date,
      valid_until: bill.valid_until,
      # Derived, not stored: "Expired" is worked out from `valid_until`, so the
      # column alone would call a lapsed bill "Active".
      status: QuantumBilling.EWayBills.status(bill),
      distance_km: bill.distance_km,
      mode_of_transport: bill.mode_of_transport,
      vehicle_number: bill.vehicle_number,
      transporter_id: bill.transporter_id,
      transporter_name: bill.transporter_name,
      cancelled_at: bill.cancelled_at,
      cancellation_reason: bill.cancellation_reason,
      invoice: %{id: bill.invoice.id, number: bill.invoice.invoice_number},
      created_at: bill.inserted_at,
      updated_at: bill.updated_at
    }
  end
end
