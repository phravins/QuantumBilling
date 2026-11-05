defmodule QuantumBilling.Events do
  @moduledoc """
  Every PubSub topic and message.

  Contexts broadcast after a write; LiveViews subscribe and update in
  `handle_info/2`. Business topics carry the business (`"invoices:biz_2"`), and
  building one with no business raises. Profile topics are per user.

  Messages: `{:client_created | :client_updated | :client_binned |
  :client_restored | :client_purged, client}`, `{:invoice_changed, invoice}`,
  `{:e_way_bill_changed, bill}`, `{:settings_updated, org}`,
  `{:invoice_template_changed, template}`, `{:profile_updated, user}`,
  `{:audit_log_created, log}`, `{:email_delivery_changed, delivery}`,
  `{:notification_created, notification}`, `{:notifications_read, :all | id}`.
  """

  @pubsub QuantumBilling.PubSub

  @doc "Subscribes the calling process to `topic`."
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  @doc "Unsubscribes the calling process from `topic`."
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  @doc """
  Publishes `message` to `topic`. Always `:ok`: a write never fails because of its notification.
  """
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
    :ok
  end

  @doc "Publishes to every process except the caller, which has already applied the change."
  def broadcast_from(topic, message) do
    Phoenix.PubSub.broadcast_from(@pubsub, self(), topic, message)
    :ok
  end

  @doc "Clients created or edited anywhere in the organisation."
  def clients_topic, do: business_topic("clients")

  @doc "Invoices created, edited or cancelled."
  def invoices_topic, do: business_topic("invoices")

  @doc "Changes to one invoice, for the public payment page (so it hears no other invoices)."
  # Business-scoped: invoice ids restart in every business's schema.
  def invoice_topic(invoice_id), do: business_topic("invoice:#{invoice_id}")

  @doc "E-way bills generated, cancelled, or moved to another vehicle. Carries an `%EWayBill{}`."
  def e_way_bills_topic, do: business_topic("e_way_bills")

  @doc "Organisation settings."
  def settings_topic, do: business_topic("settings")

  @doc """
  Invoice layouts changed. Separate from settings, since the design pad autosaves on every drag.
  """
  def invoice_templates_topic, do: business_topic("invoice_templates")

  @doc "One user's own account details, keyed by user id."
  def user_topic(user_id), do: "user:#{user_id}"

  @doc "Audit trail logs."
  def audit_logs_topic, do: business_topic("audit_logs")

  @doc "Outgoing mail: queued, sent, failed. Separate from settings, as workers publish often."
  def mail_topic, do: business_topic("mail")

  @doc "The in-app notification feed, shared by everyone in the business."
  def notifications_topic, do: business_topic("notifications")

  defp business_topic(name), do: name <> ":" <> QuantumBilling.Repo.business_schema!()
end
