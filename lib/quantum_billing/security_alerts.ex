defmodule QuantumBilling.SecurityAlerts do
  @moduledoc """
  Tells people when something security-relevant happens.

  Three kinds of event, each sent by email to whoever can act on it and
  written to the log under `[security]`, so a log system can alert on it too:

    * **Unusual sign-ins** — to the account holder. A sign-in from an address
      the account has not used in #{180} days, and a run of failed passwords
      or two-factor codes (the latter meaning someone has the password).
    * **Administrative changes** — to every owner of the business: roles
      changed, members removed or invited, API keys and webhook endpoints
      created, a full backup downloaded or restored.
    * **Unusual exports** — to every owner: a full backup always, and a burst
      of report or e-way bill exports by one person.

  Nothing here may break or slow down what triggered it: alerts are queued as
  jobs (`QuantumBilling.Workers.SecurityAlertWorker`), retried if the relay is
  down, and any failure to raise one is logged, not raised.
  """

  import Ecto.Query

  require Logger

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Workers.SecurityAlertWorker
  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.{RateLimiter, Repo}
  alias QuantumBilling.SecurityAlerts.SignIn

  @known_address_days 180
  @export_burst 30
  @export_window_seconds 3_600
  # One notice an hour per account per kind is enough to be noticed without
  # becoming the spam an attacker would want it to be.
  @notice_interval_seconds 3_600

  ## Sign-ins

  @doc """
  Records a successful sign-in, and tells the account holder when it came
  from an address the account has not used recently. The very first sign-in
  is not "new": there is nothing yet to compare it with.
  """
  def signed_in(%User{} = user, ip, user_agent, method) when is_binary(ip) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@known_address_days * 86_400, :second)

    history =
      Repo.one(
        from s in SignIn,
          where: s.user_id == ^user.id and s.inserted_at > ^cutoff,
          select: %{
            any: count(s.id),
            here: filter(count(s.id), s.ip_address == ^ip)
          }
      )

    Repo.insert!(%SignIn{
      user_id: user.id,
      ip_address: ip,
      user_agent: user_agent && String.slice(user_agent, 0, 255),
      method: to_string(method)
    })

    Repo.delete_all(from s in SignIn, where: s.user_id == ^user.id and s.inserted_at <= ^cutoff)

    if history.any > 0 and history.here == 0 do
      Logger.warning("[security] new sign-in address user=#{user.id} ip=#{ip}")

      # Throttled per address: a second unfamiliar address within the hour is
      # its own news, not a repeat.
      notify_user(user, {:new_address, ip}, "New sign-in to your account", """
      Your QuantumBilling account (#{user.email}) was just signed in to from an
      address it has not used before:

        Address: #{ip}
        Browser: #{user_agent || "unknown"}
        Time:    #{DateTime.utc_now(:second) |> DateTime.to_string()}

      If this was you, there is nothing to do.

      If it was not, reset your password now, turn on two-factor
      authentication if it is off, and tell an owner of your business.
      """)
    end

    :ok
  rescue
    error -> log_failure("sign-in", error)
  end

  @doc """
  Tells the account holder that their password has been guessed at enough
  times to lock sign-in. Says nothing when no account has that email: the
  lock already answers that caller, and this must not reveal who has one.
  """
  def failed_passwords(email, ip) when is_binary(email) do
    Logger.warning("[security] sign-in locked after failed passwords ip=#{ip}")

    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        notify_user(user, :failed_passwords, "Failed sign-in attempts on your account", """
        Several wrong passwords were just tried for your QuantumBilling account
        (#{user.email}), from #{ip}. Sign-in has been paused for a minute.

        If this was you, there is nothing to do. If not, someone is guessing
        your password: make sure it is long and used nowhere else, and turn on
        two-factor authentication.
        """)

      nil ->
        :ok
    end
  rescue
    error -> log_failure("failed passwords", error)
  end

  @doc """
  Tells the account holder that wrong two-factor codes were entered after a
  correct password. That means their password is known to someone.
  """
  def failed_two_factor(%User{} = user, ip) do
    Logger.warning(
      "[security] two-factor codes failing after a correct password user=#{user.id} ip=#{ip}"
    )

    notify_user(user, :failed_two_factor, "Your password was used, but the code was wrong", """
    Someone entered the correct password for your QuantumBilling account
    (#{user.email}) from #{ip}, then failed the two-factor code several times.

    If this was not you, your password is known to someone else. Change it
    now; your second factor is what stopped them.
    """)
  rescue
    error -> log_failure("failed two-factor", error)
  end

  @doc "Tells the account holder that two-factor authentication was switched off."
  def two_factor_disabled(%User{} = user) do
    Logger.warning("[security] two-factor disabled user=#{user.id}")

    notify_user(user, nil, "Two-factor authentication was turned off", """
    Two-factor authentication was just turned off for your QuantumBilling
    account (#{user.email}).

    If you did not do this, turn it back on and change your password now.
    """)
  rescue
    error -> log_failure("two-factor disabled", error)
  end

  ## Administration

  @doc """
  Tells every owner of `business` about an administrative change made by
  `actor`. `summary` is one sentence, e.g. "made jo@example.com an owner".
  """
  def admin_event(%Business{} = business, actor, summary) when is_binary(summary) do
    who = actor_label(actor)
    Logger.warning("[security] business=#{business.slug} actor=#{who} #{summary}")

    notify_owners(business, "#{who} #{summary}", """
    In #{business.name} on QuantumBilling, #{who} #{summary}.

    Time: #{DateTime.utc_now(:second) |> DateTime.to_string()}

    If this was expected, there is nothing to do. If not, review the Team,
    API keys and Webhooks pages and the audit log, and change the password of
    the account that did it.
    """)
  rescue
    error -> log_failure("admin event", error)
  end

  def admin_event(nil, _actor, _summary), do: :ok

  @doc """
  Counts an export by `user`. A full backup always tells the owners; other
  exports do when one person makes #{@export_burst} in an hour — the shape of
  someone copying the books out.
  """
  def exported(%Business{} = business, %User{} = user, :backup) do
    admin_event(business, user, "downloaded a full backup of the business")
  end

  def exported(%Business{} = business, %User{} = user, kind) do
    case RateLimiter.hit({:exports, business.id, user.id}, @export_burst, @export_window_seconds) do
      {:ok, 0} ->
        admin_event(
          business,
          user,
          "made #{@export_burst} exports within an hour (the latest: #{kind})"
        )

      _under_or_already_told ->
        :ok
    end
  end

  def exported(_business, _user, _kind), do: :ok

  ## Delivery

  # `throttle` names what counts as a repeat; nil sends every time.
  defp notify_user(%User{} = user, throttle, subject, body) do
    if throttle == nil or first_in_interval?({:security_notice, throttle, user.id}) do
      deliver(user.email, subject, body)
    end

    :ok
  end

  defp notify_owners(%Business{} = business, subject, body) do
    for %{role: "owner", user: %User{email: email}} <- Accounts.list_members(business) do
      deliver(email, subject, body)
    end

    :ok
  end

  defp first_in_interval?(key) do
    match?({:ok, _}, RateLimiter.hit(key, 1, @notice_interval_seconds))
  end

  # Queued: see `QuantumBilling.Workers.SecurityAlertWorker`.
  defp deliver(email, subject, body) do
    case %{"to" => email, "subject" => subject, "body" => body}
         |> SecurityAlertWorker.new()
         |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.error("[security] alert not queued: #{inspect(reason)}")
    end
  end

  defp actor_label(%User{email: email}), do: email
  defp actor_label({:api_key, name}), do: "API key \"#{name}\""
  defp actor_label(_unknown), do: "someone"

  defp log_failure(what, error) do
    Logger.error("[security] could not raise the #{what} alert: #{Exception.message(error)}")
    :ok
  end
end
