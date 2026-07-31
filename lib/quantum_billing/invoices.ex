defmodule QuantumBilling.Invoices do
  @moduledoc """
  GST invoices.

  A placeholder pending the multi-tenant Ecto schema: `list_invoices/0` returns
  nothing because no invoice table exists yet. It is here so the LiveViews stop
  owning their own records — when the schema lands this becomes a `Repo` query
  and no caller has to change.
  """

  alias QuantumBilling.Events

  @doc """
  Every invoice, newest first.

  Returns `[]` until the invoices table exists.
  """
  def list_invoices, do: []

  @doc """
  Subscribes the caller to invoice changes.

  Already wired even though nothing broadcasts yet: the Dashboard and Reports
  pages subscribe through this, so they start updating the moment invoice writes
  call `broadcast_change/2`.
  """
  def subscribe, do: Events.subscribe(Events.invoices_topic())

  @doc """
  Announces an invoice change to every listening page.
  """
  def broadcast_change(invoice, event \\ :invoice_changed) do
    Events.broadcast(Events.invoices_topic(), {event, invoice})
  end
end
