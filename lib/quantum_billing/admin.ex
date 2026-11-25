defmodule QuantumBilling.Admin do
  @moduledoc """
  What the super admin's Admin Panel reads: the installation's version, its
  users and businesses, its configuration and its health.

  Every function here spans all businesses, so only `QuantumBillingWeb.AdminLive`,
  behind `:require_admin`, may call it.
  """

  import Ecto.Query

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.{Business, Membership}
  alias QuantumBilling.{GitHub, Release, Repo}

  @list_limit 20

  ## Version

  @doc "The running version, such as `\"0.1.0\"`."
  def current_version, do: :quantum_billing |> Application.spec(:vsn) |> to_string()

  @doc """
  The running and latest released versions. `latest` is `nil` when GitHub
  could not be reached or has no release; `update?` says whether to upgrade.
  """
  def version_info do
    current = current_version()

    latest =
      case GitHub.latest_release() do
        {:ok, tag} -> String.trim_leading(tag, "v")
        {:error, _reason} -> nil
      end

    %{current: current, latest: latest, update?: newer?(latest, current)}
  end

  defp newer?(latest, current) when is_binary(latest) do
    with {:ok, latest} <- Version.parse(latest),
         {:ok, current} <- Version.parse(current) do
      Version.compare(latest, current) == :gt
    else
      _ -> false
    end
  end

  defp newer?(_latest, _current), do: false

  ## Users and businesses

  @doc "The super admins, by email."
  def admins do
    Repo.all(from u in User, where: u.is_admin, order_by: [asc: u.email])
  end

  @doc """
  The newest users, optionally those whose email, username or name contains
  `search`. Each comes with `:business_count`.
  """
  def recent_users(search \\ "") do
    from(u in User,
      left_join: m in Membership,
      on: m.user_id == u.id,
      group_by: u.id,
      order_by: [desc: u.inserted_at, desc: u.id],
      limit: @list_limit,
      select: %{user: u, business_count: count(m.id)}
    )
    |> search_users(search)
    |> Repo.all()
    |> Enum.map(fn %{user: user, business_count: count} ->
      %{
        id: user.id,
        email: user.email,
        name: user.full_name || user.username,
        joined_at: user.inserted_at,
        business_count: count
      }
    end)
  end

  defp search_users(query, search) do
    case like_pattern(search) do
      nil ->
        query

      pattern ->
        where(
          query,
          [u],
          ilike(u.email, ^pattern) or ilike(u.username, ^pattern) or
            ilike(u.full_name, ^pattern)
        )
    end
  end

  @doc """
  The active businesses with the most members, optionally those whose name or
  slug contains `search`.
  """
  def top_businesses(search \\ "") do
    query =
      from(b in Business,
        left_join: m in Membership,
        on: m.business_id == b.id,
        where: is_nil(b.archived_at),
        group_by: b.id,
        order_by: [desc: count(m.id), asc: b.name],
        limit: @list_limit,
        select: %{id: b.id, name: b.name, slug: b.slug, member_count: count(m.id)}
      )

    query =
      case like_pattern(search) do
        nil -> query
        pattern -> where(query, [b], ilike(b.name, ^pattern) or ilike(b.slug, ^pattern))
      end

    Repo.all(query)
  end

  # `%`, `_` and `\` are matched literally, so a search cannot widen itself.
  defp like_pattern(search) when is_binary(search) do
    case String.trim(search) do
      "" -> nil
      term -> "%" <> String.replace(term, ~r/[\\%_]/, "\\\\\\0") <> "%"
    end
  end

  defp like_pattern(_search), do: nil

  ## Config

  # {name, description}. Only names, never values, are listed here.
  @config_vars [
    {"PHX_HOST", "Public host name used in links and emails"},
    {"PORT", "Port the web server listens on"},
    {"PHX_SERVER", "Starts the web server in a release"},
    {"PHX_CHECK_ORIGIN", "Extra origins allowed to open a LiveView socket"},
    {"SECRET_KEY_BASE", "Signs and encrypts cookies and tokens"},
    {"DATABASE_URL", "Database connection in production"},
    {"DATABASE_SSL", "Whether the database connection uses TLS"},
    {"DB_HOSTNAME", "Database host in development and test"},
    {"DB_PORT", "Database port in development and test"},
    {"DB_NAME", "Database name in development"},
    {"DB_USERNAME", "Database user in development and test"},
    {"DB_PASSWORD", "Database password in development and test"},
    {"POOL_SIZE", "Database connections per node"},
    {"SLOW_QUERY_MS", "Queries slower than this are logged"},
    {"TOTP_ENCRYPTION_KEY", "Encrypts two-factor secrets at rest"},
    {"SECRETS_ENCRYPTION_KEY", "Encrypts business secrets at rest, such as SMTP passwords"},
    {"SMTP_HOST", "Mail relay for system email"},
    {"SMTP_PORT", "Mail relay port"},
    {"SMTP_USERNAME", "Mail relay user"},
    {"SMTP_PASSWORD", "Mail relay password"},
    {"SMTP_SSL", "Uses implicit TLS for the mail relay"},
    {"SMTP_TLS_VERIFY", "Verifies the mail relay's certificate"},
    {"MAILER_FROM_EMAIL", "Sender address for system email"},
    {"GOOGLE_CALENDAR_CLIENT_ID", "OAuth client for Google Calendar sync"},
    {"GOOGLE_CALENDAR_CLIENT_SECRET", "OAuth secret for Google Calendar sync"},
    {"UPLOADS_DIR", "Where uploaded logos and files are stored"},
    {"TRUSTED_PROXIES", "Proxies whose X-Forwarded-For is trusted"},
    {"DNS_CLUSTER_QUERY", "DNS name used to find other nodes"}
  ]

  @secret ~r/PASSWORD|SECRET|KEY|TOKEN|DATABASE_URL/

  @doc """
  The environment variables the app reads, as maps with `:name`,
  `:description`, `:secret?` and `:value`. A secret's value is never returned:
  it is `"••••••"` when set. An unset variable's value is `nil`.
  """
  def config_vars(search \\ "") do
    term = search |> to_string() |> String.trim() |> String.downcase()

    for {name, description} <- @config_vars,
        term == "" or String.contains?(String.downcase(name <> " " <> description), term) do
      secret? = Regex.match?(@secret, name)
      raw = System.get_env(name)
      set? = is_binary(raw) and raw != ""

      %{
        name: name,
        description: description,
        secret?: secret?,
        value:
          cond do
            not set? -> nil
            secret? -> "••••••"
            true -> raw
          end
      }
    end
  end

  ## Health

  @doc """
  The status of each part of the installation, as maps with `:key`, `:name`,
  `:status` (`:ok`, `:degraded` or `:off`) and `:detail`.
  """
  def health_checks do
    [database_check(), jobs_check(), email_check(), calendar_check(), storage_check()]
  end

  defp database_check do
    started = System.monotonic_time(:microsecond)

    case Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} ->
        ms = (System.monotonic_time(:microsecond) - started) / 1000

        check(
          :database,
          "Database",
          :ok,
          "Answered in #{:erlang.float_to_binary(ms, decimals: 1)} ms"
        )

      {:error, _error} ->
        check(:database, "Database", :degraded, "Did not answer")
    end
  end

  defp jobs_check do
    failed =
      Repo.one(
        from(j in "oban_jobs",
          where: j.state == "discarded" and j.discarded_at > ago(1, "day"),
          select: count(j.id)
        ),
        prefix: "public"
      )

    queues = Oban.check_all_queues()
    testing? = Oban.config().testing != :disabled

    cond do
      testing? ->
        check(:jobs, "Background jobs", :ok, "Run inline (test mode)")

      queues == [] ->
        check(:jobs, "Background jobs", :degraded, "No queues are running on this node")

      failed > 0 ->
        check(:jobs, "Background jobs", :degraded, "#{failed} failed in the last 24 hours")

      true ->
        check(
          :jobs,
          "Background jobs",
          :ok,
          "#{length(queues)} queues running, none failed today"
        )
    end
  end

  defp email_check do
    adapter = Application.get_env(:quantum_billing, QuantumBilling.Mailer, [])[:adapter]

    case adapter do
      Swoosh.Adapters.SMTP -> check(:email, "System email", :ok, "Sent through the SMTP relay")
      Swoosh.Adapters.Local -> check(:email, "System email", :off, "Local mailbox (development)")
      Swoosh.Adapters.Test -> check(:email, "System email", :off, "Test adapter")
      _other -> check(:email, "System email", :off, "No relay set; businesses use their own SMTP")
    end
  end

  defp calendar_check do
    config = Application.get_env(:quantum_billing, :google_calendar, [])

    if present?(config[:client_id]) and present?(config[:client_secret]),
      do: check(:calendar, "Google Calendar", :ok, "OAuth client configured"),
      else: check(:calendar, "Google Calendar", :off, "Not configured")
  end

  defp storage_check do
    dir = QuantumBilling.Uploads.directory()

    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:read_write, :write] ->
        check(:storage, "File storage", :ok, "Writable")

      {:ok, _stat} ->
        check(:storage, "File storage", :degraded, "Not writable")

      {:error, :enoent} ->
        check(:storage, "File storage", :off, "Created on first upload")

      {:error, _reason} ->
        check(:storage, "File storage", :degraded, "Cannot be read")
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp check(key, name, status, detail),
    do: %{key: key, name: name, status: status, detail: detail}

  @doc """
  Whether the database is up to date: pending public migrations, and how many
  business schemas have none pending out of the total.
  """
  def upgrade_status do
    public_pending =
      for {:down, version, _name} <- Ecto.Migrator.migrations(Repo), do: version

    total = Repo.aggregate(from(b in Business), :count, prefix: "public")
    behind = length(Release.pending_business_migrations(Repo))

    %{
      version: current_version(),
      public_pending: length(public_pending),
      businesses_total: total,
      businesses_current: total - behind
    }
  end
end
