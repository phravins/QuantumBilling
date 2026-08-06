defmodule QuantumBilling.Events do
  @moduledoc """
  Every PubSub topic and message in the application, in one place.

  Contexts broadcast after a successful write; LiveViews subscribe on connect
  and patch themselves in `handle_info/2`. Nothing subscribes to a topic it does
  not own a handler for.

  ## Scoping

  Records like clients, invoices and organisation settings belong to the
  *organisation*, not to whoever happened to create them: two signed-in users
  looking at `/clients` are looking at the same list, so those topics are global
  and both windows update.

  A user's own profile is different — changing your name should refresh your
  sidebar in your other tabs, not everyone else's — so that one is keyed by user
  id.

  When schema-per-tenant lands, the organisation topics gain the tenant in their
  name and every publisher and subscriber follows from this module alone. That
  is the reason topics are built here rather than written as string literals at
  each call site.

  ## Messages

      {:client_created, client}
      {:client_updated, client}
      {:invoice_changed, invoice}
      {:e_way_bill_changed, e_way_bill}
      {:settings_updated, organization}
      {:invoice_template_changed, template}
      {:profile_updated, user}
  """

  @pubsub QuantumBilling.PubSub

  @doc "Subscribes the calling process to `topic`."
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  @doc "Unsubscribes the calling process from `topic`."
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  @doc """
  Publishes `message` to `topic`.

  Always returns `:ok`, including when nobody is listening — a write must never
  fail because of its own notification.
  """
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
    :ok
  end

  @doc """
  Publishes to every process except the caller.

  Used where the writer has already applied the change locally and re-rendering
  from the broadcast would discard its own form state.
  """
  def broadcast_from(topic, message) do
    Phoenix.PubSub.broadcast_from(@pubsub, self(), topic, message)
    :ok
  end

  # ── Topics ─────────────────────────────────────────────────────────────────

  @doc "Clients created or edited anywhere in the organisation."
  def clients_topic, do: "clients"

  @doc "Invoices created, edited or cancelled."
  def invoices_topic, do: "invoices"

  @doc "E-way bills generated or cancelled."
  def e_way_bills_topic, do: "e_way_bills"

  @doc "Organisation settings."
  def settings_topic, do: "settings"

  @doc """
  Invoice layouts created, edited, archived or made default.

  Separate from `settings_topic/0` even though the design pad is reached through
  Settings: the pad autosaves on every drag, and a settings window has no reason
  to rebuild its form each time somebody nudges a block in another tab.
  """
  def invoice_templates_topic, do: "invoice_templates"

  @doc """
  One user's own account details.

  Keyed by id: a profile change belongs to that user's windows, not to everyone.
  """
  def user_topic(user_id), do: "user:#{user_id}"
end
