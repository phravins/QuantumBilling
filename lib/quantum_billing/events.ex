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

  Organisation topics carry the business in their name — `"invoices:biz_2"` —
  taken from the business the calling process works in (see
  `QuantumBilling.Repo.business/0`). A window open on one firm hears nothing
  about another's invoices, and no publisher or subscriber has to say which
  business it means: both already run inside one. Building a topic with no
  business chosen raises, like a query would, rather than falling back to a
  topic every firm shares.

  ## Messages

      {:client_created, client}
      {:client_updated, client}
      {:client_binned, client}
      {:client_restored, client}
      {:client_purged, client}
      {:invoice_changed, invoice}
      {:e_way_bill_changed, e_way_bill}
      {:settings_updated, organization}
      {:invoice_template_changed, template}
      {:profile_updated, user}
      {:audit_log_created, log}
      {:email_delivery_changed, delivery}
      {:notification_created, notification}
      {:notifications_read, :all | id}
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
  def clients_topic, do: business_topic("clients")

  @doc "Invoices created, edited or cancelled."
  def invoices_topic, do: business_topic("invoices")

  @doc """
  Changes to a single invoice.

  For listeners that care about exactly one — above all the public payment
  page, which is unauthenticated. It used to subscribe to `invoices_topic/0`,
  so every invoice change in the business was delivered into every customer's
  session and thrown away on arrival. Nothing reached the screen, because the
  page checked the id first, but a process holding other customers' invoices
  is one careless line from showing them — and the fan-out grew with every
  customer looking at a bill.
  """
  #
  # Business-scoped like the rest: ids restart in every business's schema, so
  # `invoice:7` alone would join one firm's customer page to another firm's
  # invoice 7.
  def invoice_topic(invoice_id), do: business_topic("invoice:#{invoice_id}")

  @doc """
  E-way bills generated, cancelled, or moved to another vehicle.

  The message carries an `%EWayBill{}`, which it could not before: until the
  bill had a table of its own, the publisher had nothing but the invoice to
  send, so this topic broadcast one while its documented message said
  otherwise.
  """
  def e_way_bills_topic, do: business_topic("e_way_bills")

  @doc "Organisation settings."
  def settings_topic, do: business_topic("settings")

  @doc """
  Invoice layouts created, edited, archived or made default.

  Separate from `settings_topic/0` even though the design pad is reached through
  Settings: the pad autosaves on every drag, and a settings window has no reason
  to rebuild its form each time somebody nudges a block in another tab.
  """
  def invoice_templates_topic, do: business_topic("invoice_templates")

  @doc """
  One user's own account details.

  Keyed by id: a profile change belongs to that user's windows, not to everyone.
  """
  def user_topic(user_id), do: "user:#{user_id}"

  @doc "Audit trail logs."
  def audit_logs_topic, do: business_topic("audit_logs")

  @doc """
  Outgoing mail: queued, sent, failed.

  Its own topic rather than part of `settings_topic/0`, even though the
  delivery list is shown in Settings: a background mail worker publishes here
  several times per message, and a settings window has no reason to rebuild its
  form each time an invoice goes out.
  """
  def mail_topic, do: business_topic("mail")

  @doc """
  The in-app notification feed.

  Organisation-wide, like the records it reports on: the bell shows the same
  feed to everyone signed in, and clearing it clears it for the business. Its
  own topic rather than a share of the others' because every authenticated page
  subscribes to this one — a page that has no interest in invoices still draws
  the bell — and because the producers are spread across contexts, workers and
  a payment webhook.
  """
  def notifications_topic, do: business_topic("notifications")

  defp business_topic(name), do: name <> ":" <> QuantumBilling.Repo.business_schema!()
end
