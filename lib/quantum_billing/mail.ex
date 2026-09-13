defmodule QuantumBilling.Mail do
  @moduledoc """
  Everything about *how* mail leaves this application: which relay, over what
  kind of connection, under whose address, and what is recorded about it.

  What each message *says* stays with whoever composes it —
  `QuantumBilling.InvoiceNotifier` for invoices, `Accounts.UserNotifier` for
  sign-in mail. Both hand the finished `Swoosh.Email` here, so there is exactly
  one place that decides transport, and a change to TLS or to the sender is not
  something that has to be repeated per message type.

  ## Which relay

  The organisation's own SMTP settings win when a host is configured. Nothing
  is configured on a fresh install, so mail falls back to the application
  mailer — the local preview in development, the `SMTP_*` environment in
  production. Either way the caller gets the same `{:ok, meta}` or
  `{:error, message}` with a message meant for a human.

  ## TLS

  Connections are verified: `verify_peer` against the system trust store, with
  the hostname checked against the certificate. Without that, "encrypted" means
  only that nobody *passively* reads the SMTP password — anyone in a position
  to answer for the relay collects it, and an invoice PDF goes to them instead
  of to the customer.

  Port 465 connects with TLS immediately; everything else connects in the clear
  and is required to upgrade with STARTTLS before credentials are sent. A relay
  that cannot upgrade fails rather than silently sending the password in the
  clear.

  `SMTP_TLS_VERIFY=false` turns verification off for a relay using a
  self-signed certificate on a trusted network. It is deliberately a
  deployment-level switch and not a per-organisation setting: it is the kind of
  thing that should need a deploy, not a form.
  """

  import Ecto.Query, warn: false

  require Logger

  alias QuantumBilling.Events
  alias QuantumBilling.Mail.Delivery
  alias QuantumBilling.Mailer
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  @connect_timeout_ms 15_000

  @doc """
  Sends `email` now, through the organisation's relay when one is configured.

  Returns `{:ok, metadata}` or `{:error, message}`, where the message is
  already phrased for the person who has to fix it.
  """
  def deliver(email, organization \\ nil)

  def deliver(%Swoosh.Email{} = email, nil) do
    deliver(email, Settings.get_organization())
  end

  def deliver(%Swoosh.Email{} = email, %Organization{} = organization) do
    case Mailer.deliver(email, smtp_config(organization)) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, error_message(reason)}
    end
  rescue
    # gen_smtp raises rather than returning for some option and DNS failures,
    # and a background job or a LiveView should not come down with it.
    exception -> {:error, error_message(exception)}
  end

  @doc """
  The Swoosh config for the organisation's relay, or `[]` to use the
  application mailer.

  Returned as a keyword list rather than applied globally: per-call config is
  what keeps the test adapter in place during tests, and what lets two
  organisations differ once tenancy lands.
  """
  def smtp_config(%Organization{} = organization) do
    case presence(organization.smtp_host) do
      nil ->
        []

      host ->
        port = organization.smtp_port || 587
        implicit_tls? = organization.smtp_ssl == true or port == 465
        tls = tls_options(host)

        [
          adapter: Swoosh.Adapters.SMTP,
          relay: host,
          port: port,
          username: presence(organization.smtp_username),
          password: presence(organization.smtp_password),
          # Implicit TLS from the first byte on 465; STARTTLS everywhere else,
          # required rather than opportunistic.
          ssl: implicit_tls?,
          tls: if(implicit_tls?, do: :never, else: :always),
          tls_options: tls,
          sockopts: if(implicit_tls?, do: tls, else: []),
          auth: if(presence(organization.smtp_username), do: :always, else: :never),
          # A relay named by hostname is the relay to use. An MX lookup would
          # quietly send the mail somewhere else.
          no_mx_lookups: true,
          timeout: @connect_timeout_ms,
          # Oban owns retrying, with backoff and a record of each attempt.
          # gen_smtp retrying inside the job as well would multiply the two.
          retries: 0
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  def smtp_config(_no_organization), do: []

  @doc "Whether the organisation has its own relay configured."
  def own_relay?(%Organization{} = organization), do: presence(organization.smtp_host) != nil
  def own_relay?(_organization), do: false

  @doc """
  The `{name, email}` an outgoing message is sent from.

  The configured sender address wins, then the organisation's own contact
  address, then `MAILER_FROM_EMAIL`. Relays reject mail from an address they do
  not host, so this is the setting most likely to be the real cause of a
  delivery failure — hence one place to resolve it.
  """
  def sender(organization \\ nil, fallback_name \\ nil)

  def sender(nil, fallback_name), do: sender(Settings.get_organization(), fallback_name)

  def sender(%Organization{} = organization, fallback_name) do
    email =
      presence(organization.smtp_from_email) ||
        presence(organization.email) ||
        System.get_env("MAILER_FROM_EMAIL") ||
        "invoices@quantumbilling.in"

    name =
      presence(organization.smtp_from_name) ||
        presence(fallback_name) ||
        presence(organization.company_name) ||
        "QuantumBilling"

    {name, email}
  end

  @doc """
  Sends a test message through the configured relay, right now.

  Deliberately synchronous and deliberately small: the point of the button in
  Settings is to find out what the relay says, so the answer has to come back
  to the person who pressed it rather than to a log. It carries no attachment,
  so a failure is about the connection and the credentials rather than about
  rendering a PDF.
  """
  def send_test(recipient) when is_binary(recipient) do
    organization = Settings.get_organization()
    {from_name, from_email} = sender(organization)
    subject = "QuantumBilling SMTP test"

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient)
      |> Swoosh.Email.from({from_name, from_email})
      |> Swoosh.Email.subject(subject)
      |> Swoosh.Email.text_body("""
      This is a test message from QuantumBilling.

      If you are reading it, the mail settings work: the relay accepted the
      message from #{from_email} and delivered it here.

      Relay: #{organization.smtp_host || "application default"}
      """)

    delivery =
      case record_queued(%{to_email: recipient, kind: "test", subject: subject}) do
        {:ok, delivery} -> delivery
        {:error, _changeset} -> nil
      end

    case deliver(email, organization) do
      {:ok, metadata} ->
        delivery && mark_sent(delivery)
        {:ok, metadata}

      {:error, message} ->
        delivery && mark_failed(delivery, message, true)
        {:error, message}
    end
  end

  # ── The delivery ledger ───────────────────────────────────────────────────

  @doc """
  Records that a message is about to be attempted.

  Written before the job is enqueued so that a message which never reaches the
  relay — or never reaches a worker — is still visible as something that was
  asked for and did not arrive.
  """
  def record_queued(attrs) do
    %Delivery{}
    |> Delivery.changeset(attrs)
    |> Repo.insert()
    |> broadcast_delivery()
  end

  @doc "Marks a delivery as sent, stamping the time it was accepted."
  def mark_sent(%Delivery{} = delivery) do
    delivery
    |> Delivery.status_changeset(%{
      status: "sent",
      attempts: delivery.attempts + 1,
      last_error: nil,
      delivered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> broadcast_delivery()
  end

  @doc """
  Records a failed attempt.

  `final?` separates "this attempt failed and another is coming" from "this is
  as far as it goes", so the ledger does not show a message as failed while
  Oban still intends to retry it.
  """
  def mark_failed(%Delivery{} = delivery, reason, final?) do
    delivery
    |> Delivery.status_changeset(%{
      status: if(final?, do: "failed", else: "queued"),
      attempts: delivery.attempts + 1,
      last_error: String.slice(to_string(reason), 0, 1_000)
    })
    |> Repo.update()
    |> broadcast_delivery()
  end

  @doc "One delivery by id, or `nil`."
  def get_delivery(id), do: Repo.get(Delivery, id)

  @doc """
  The most recent delivery attempts, newest first.

  Bounded by design — this is the "did it go out?" panel, not an archive.
  """
  def list_recent_deliveries(limit \\ 20) do
    Repo.all(from d in Delivery, order_by: [desc: d.inserted_at, desc: d.id], limit: ^limit)
  end

  @doc "How many deliveries are in each state, for a status line."
  def delivery_counts do
    Repo.all(from d in Delivery, group_by: d.status, select: {d.status, count(d.id)})
    |> Map.new()
  end

  @doc "Subscribes the caller to delivery updates."
  def subscribe, do: Events.subscribe(Events.mail_topic())

  defp broadcast_delivery({:ok, %Delivery{} = delivery} = result) do
    Events.broadcast(Events.mail_topic(), {:email_delivery_changed, delivery})
    result
  end

  defp broadcast_delivery(result), do: result

  # ── TLS ───────────────────────────────────────────────────────────────────

  defp tls_options(host) do
    if verify_tls?() do
      [
        verify: :verify_peer,
        cacerts: cacerts(),
        depth: 3,
        # Both are needed: SNI so a shared relay presents the right
        # certificate, and the hostname match so the certificate it presents is
        # actually for the host we asked for.
        server_name_indication: to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        versions: [:"tlsv1.2", :"tlsv1.3"]
      ]
    else
      [verify: :verify_none, versions: [:"tlsv1.2", :"tlsv1.3"]]
    end
  end

  defp verify_tls?, do: Application.get_env(:quantum_billing, :smtp_tls_verify, true)

  defp cacerts do
    :public_key.cacerts_get()
  rescue
    _no_trust_store ->
      reraise """
              No system CA trust store was found, so the SMTP server's
              certificate cannot be verified.

              Install your platform's CA bundle (the `ca-certificates` package
              on Debian and Ubuntu images), or set SMTP_TLS_VERIFY=false if
              this relay is reached over a network you already trust.
              """,
              __STACKTRACE__
  end

  # ── Error messages ────────────────────────────────────────────────────────

  @doc """
  Turns a transport failure into something a person can act on.

  Public because the same failures surface from the settings "send test" button
  and from the mail worker, and both should describe them the same way.
  """
  def error_message({:retries_exceeded, reason}),
    do: "SMTP retries exceeded: #{error_message(reason)}"

  def error_message({:network_failure, host, {:error, :timeout}}),
    do: "Timed out connecting to #{to_string(host)}. Check the host, the port and any firewall."

  def error_message({:network_failure, host, {:error, :econnrefused}}),
    do: "#{to_string(host)} refused the connection. Check the host and port."

  def error_message({:network_failure, host, {:error, :nxdomain}}),
    do: "#{to_string(host)} could not be resolved. Check the SMTP host."

  def error_message({:network_failure, host, {:error, {:tls_alert, {_alert, detail}}}}),
    do:
      "TLS handshake with #{to_string(host)} failed: #{to_string(detail)}. " <>
        "The certificate may not match the host, or may not be signed by a trusted authority."

  def error_message({:network_failure, host, detail}),
    do: "Network failure connecting to #{to_string(host)}: #{error_message(detail)}"

  def error_message({:missing_requirement, _host, :auth}),
    do:
      "The relay refused to authenticate over this connection. " <>
        "Check the port (587 for STARTTLS, 465 for SSL) and the SSL toggle."

  def error_message({:missing_requirement, _host, :tls}),
    do:
      "The relay does not offer STARTTLS, so the password cannot be sent safely. " <>
        "Use port 465 with SSL, or a relay that supports STARTTLS."

  def error_message(:auth_failed),
    do: "The relay rejected the username or password."

  def error_message({:auth_failed, detail}),
    do: "The relay rejected the username or password: #{error_message(detail)}"

  def error_message({:permanent_failure, _host, detail}),
    do: "The relay rejected the message: #{error_message(detail)}"

  def error_message(:econnrefused), do: "The SMTP server refused the connection."
  def error_message(:timeout), do: "The SMTP server did not answer in time."
  def error_message(:nxdomain), do: "The SMTP host could not be resolved."

  def error_message(%{__exception__: true} = exception),
    do: Exception.message(exception)

  def error_message(charlist) when is_list(charlist) do
    if List.ascii_printable?(charlist), do: List.to_string(charlist), else: inspect(charlist)
  end

  def error_message({reason, detail}), do: "#{error_message(reason)}: #{error_message(detail)}"
  def error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_message(reason) when is_binary(reason), do: reason
  def error_message(reason), do: inspect(reason)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
