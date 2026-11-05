defmodule QuantumBillingWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :quantum_billing

  @session_options [
    store: :cookie,
    key: "_quantum_billing_key",
    signing_salt: "QEN7M6qy",
    # Encrypted as well as signed, so the cookie's contents are not readable.
    encryption_salt: "B3jws6iS",
    same_site: "Lax",
    # HTTPS-only in production (config/prod.exs), so the browser never sends
    # the session over plain HTTP. Off in dev and test, which run without TLS.
    secure: Application.compile_env(:quantum_billing, :secure_session_cookie, false)
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :quantum_billing,
    gzip: not code_reloading?,
    only: QuantumBillingWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :quantum_billing
    plug QuantumBillingWeb.Plugs.CheckBusinessMigrations
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}

  # No multipart: uploads go through LiveView, so this keeps unauthenticated
  # requests from spooling files. 2MB covers any form or API body.
  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    length: 2_000_000,
    pass: ["*/*"],
    # Signatures cover the raw bytes; see RawBodyReader.
    body_reader: {QuantumBillingWeb.RawBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug :forget_business
  plug QuantumBillingWeb.Router

  @doc """
  The level to log a request at. These paths carry a bearer token, so writing
  them to the request log would hand access to anyone who can read the log.
  """
  def log_level(%Plug.Conn{path_info: ["calendar" | _rest]}), do: false
  def log_level(%Plug.Conn{path_info: ["p" | _rest]}), do: false
  def log_level(%Plug.Conn{path_info: ["pay" | _rest]}), do: false
  def log_level(%Plug.Conn{path_info: ["users", "log-in", _token]}), do: false
  def log_level(%Plug.Conn{path_info: ["users", "settings", "confirm-email", _token]}), do: false
  def log_level(%Plug.Conn{}), do: :info

  # Keep-alive connections reuse one process, so clear the business per request
  # and restore the previous one afterwards (tests rely on that).
  defp forget_business(conn, _opts) do
    previous = QuantumBilling.Repo.business()
    QuantumBilling.Repo.put_business(nil)

    register_before_send(conn, fn conn ->
      QuantumBilling.Repo.put_business(previous)
      conn
    end)
  end
end
