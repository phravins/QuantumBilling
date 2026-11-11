defmodule QuantumBilling.Mail do
  @moduledoc """
  How mail leaves the app: relay, TLS, sender address and the delivery ledger.

  The organisation's SMTP settings win when a host is set; otherwise the app
  mailer is used. Connections verify the relay's certificate (465 is implicit
  TLS, other ports require STARTTLS). `SMTP_TLS_VERIFY=false` turns that off
  for self-signed relays.
  """

  import Ecto.Query, warn: false

  require Logger

  alias QuantumBilling.Events
  alias QuantumBilling.Mail.Delivery
  alias QuantumBilling.Mailer
  alias QuantumBilling.Notifications
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  @connect_timeout_ms 15_000

  @doc "Sends `email` now. Returns `{:ok, meta}` or `{:error, human_message}`."
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
    # gen_smtp raises on some option and DNS failures.
    exception -> {:error, error_message(exception)}
  end

  @doc "The Swoosh config for the organisation's relay, or `[]` for the app mailer."
  def smtp_config(%Organization{} = organization) do
    case usable_relay(organization) do
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
          # Implicit TLS on 465; required STARTTLS elsewhere.
          ssl: implicit_tls?,
          tls: if(implicit_tls?, do: :never, else: :always),
          tls_options: tls,
          sockopts: if(implicit_tls?, do: tls, else: []),
          auth: if(presence(organization.smtp_username), do: :always, else: :never),
          no_mx_lookups: true,
          timeout: @connect_timeout_ms,
          # Oban handles retries.
          retries: 0
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  def smtp_config(_no_organization), do: []

  # A username without a password can't authenticate; use the app mailer instead.
  defp usable_relay(%Organization{} = organization) do
    host = presence(organization.smtp_host)
    username = presence(organization.smtp_username)
    password = presence(organization.smtp_password)

    cond do
      is_nil(host) ->
        nil

      username && is_nil(password) ->
        Logger.warning(
          "SMTP relay #{host} has a username but no password — falling back to the " <>
            "application mailer. Re-enter the password under Settings > SMTP."
        )

        nil

      true ->
        host
    end
  end

  @doc "Whether the organisation has its own relay configured."
  def own_relay?(%Organization{} = organization), do: presence(organization.smtp_host) != nil
  def own_relay?(_organization), do: false

  @doc """
  The `{name, email}` to send from: configured sender, then contact email, then `MAILER_FROM_EMAIL`.
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

  @doc "Sends a small test message synchronously, so Settings can show the relay's answer."
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

  # The delivery ledger

  @doc "Records a message before its job is enqueued, so a lost send stays visible."
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

  @doc "Records a failed attempt. `final?` is true when no retry is coming."
  def mark_failed(%Delivery{} = delivery, reason, final?) do
    result =
      delivery
      |> Delivery.status_changeset(%{
        status: if(final?, do: "failed", else: "queued"),
        attempts: delivery.attempts + 1,
        last_error: String.slice(to_string(reason), 0, 1_000)
      })
      |> Repo.update()
      |> broadcast_delivery()

    # Only on the final failure.
    if final? do
      Notifications.notify(%{
        kind: "mail",
        severity: "error",
        title: "Email to #{delivery.to_email} failed",
        body: error_message(reason),
        path: "/settings/smtp",
        dedupe_key: "mail_failed:#{delivery.id}"
      })
    end

    result
  end

  @doc "One delivery by id, or `nil`."
  def get_delivery(id), do: Repo.get(Delivery, id)

  @doc "Removes a delivery. A queued job then finds it gone and is discarded."
  def delete_delivery(id) do
    case get_delivery(id) do
      nil -> {:error, :not_found}
      delivery -> delivery |> Repo.delete() |> broadcast_delivery()
    end
  end

  @doc "The most recent delivery attempts, newest first."
  def list_recent_deliveries(limit \\ 20) do
    Repo.all(from d in Delivery, order_by: [desc: d.inserted_at, desc: d.id], limit: ^limit)
  end

  @doc "Subscribes the caller to delivery updates."
  def subscribe, do: Events.subscribe(Events.mail_topic())

  defp broadcast_delivery({:ok, %Delivery{} = delivery} = result) do
    Events.broadcast(Events.mail_topic(), {:email_delivery_changed, delivery})
    result
  end

  defp broadcast_delivery(result), do: result

  # TLS

  defp tls_options(host) do
    if verify_tls?() do
      [
        verify: :verify_peer,
        cacerts: cacerts(),
        depth: 3,
        server_name_indication: to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        verify_fun: {&__MODULE__.verify_cert/3, nil},
        versions: [:"tlsv1.2", :"tlsv1.3"],
        middlebox_comp_mode: false
      ]
    else
      [verify: :verify_none, versions: [:"tlsv1.2", :"tlsv1.3"], middlebox_comp_mode: false]
    end
  end

  # Some relays never send TLS 1.3 change_cipher_spec, which OTP 27 requires.

  @doc """
  Certificate check for relay connections.

  Same as OTP's default, except it accepts CA certificates with both
  keyCertSign and serverAuth (as in Let's Encrypt's ISRG Root YR), which
  OTP 27.2 rejects. Also used by `config/runtime.exs`.
  """
  def verify_cert(
        _cert,
        {:bad_cert, {:key_usage_mismatch, {key_usage, _ext_key_usage}}} = reason,
        state
      ) do
    case key_usage do
      {:Extension, _oid, _critical, usages} when is_list(usages) ->
        if :keyCertSign in usages, do: {:valid, state}, else: {:fail, reason}

      _other ->
        {:fail, reason}
    end
  end

  def verify_cert(_cert, {:bad_cert, _} = reason, _state), do: {:fail, reason}
  def verify_cert(_cert, {:extension, _}, state), do: {:unknown, state}
  def verify_cert(_cert, :valid, state), do: {:valid, state}
  def verify_cert(_cert, :valid_peer, state), do: {:valid, state}

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

  # Error messages

  @doc "Turns a transport failure into a message a person can act on."
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
