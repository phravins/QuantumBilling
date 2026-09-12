defmodule QuantumBilling.EWayBills do
  @moduledoc """
  Context for managing E-Way Bills and communicating with Govt NIC API.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.Audit
  alias QuantumBilling.Repo

  @doc """
  Generates an E-Way Bill for an invoice and stores the details on the invoice.
  """
  def generate_e_way_bill(%Invoice{} = invoice, params \\ %{}) do
    case NICClient.generate_ewb(invoice, params) do
      {:ok, ewb_attrs} ->
        changeset = Ecto.Changeset.change(invoice, ewb_attrs)

        case Repo.update(changeset) do
          {:ok, updated_invoice} ->
            Audit.log_event(
              :generate_e_way_bill,
              "Invoice",
              updated_invoice.id,
              details: %{
                ewb_number: updated_invoice.ewb_number,
                distance_km: updated_invoice.distance_km,
                vehicle_number: updated_invoice.vehicle_number
              }
            )

            broadcast_change(updated_invoice)
            {:ok, updated_invoice}

          {:error, cs} ->
            {:error, cs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Every e-way bill, newest first.
  """
  def list_e_way_bills do
    Repo.all(from i in Invoice, where: not is_nil(i.ewb_number), order_by: [desc: i.ewb_date])
  end

  @doc """
  Subscribes the caller to e-way bill changes.
  """
  def subscribe, do: Events.subscribe(Events.e_way_bills_topic())

  @doc """
  Announces an e-way bill change to every listening page.
  """
  def broadcast_change(e_way_bill, event \\ :e_way_bill_changed) do
    Events.broadcast(Events.e_way_bills_topic(), {event, e_way_bill})
  end
end
