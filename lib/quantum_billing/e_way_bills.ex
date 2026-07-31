defmodule QuantumBilling.EWayBills do
  @moduledoc """
  Issued e-way bills.

  A placeholder pending the multi-tenant Ecto schema: `list_e_way_bills/0`
  returns nothing because no e-way bill table exists yet. It is here so the
  LiveViews stop owning their own records — when the schema lands this becomes a
  `Repo` query and no caller has to change.

  `QuantumBilling.EWayBills.EWayBillForm` already models the generate form and
  is unaffected; it validates input rather than reading stored records.
  """

  alias QuantumBilling.Events

  @doc """
  Every e-way bill, newest first.

  Returns `[]` until the e-way bills table exists.
  """
  def list_e_way_bills, do: []

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
