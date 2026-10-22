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

  # Before Plug.Static: uploaded content needs its own headers.
  plug QuantumBillingWeb.Plugs.StaticHardening

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
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    # Signatures cover the raw bytes; see RawBodyReader.
    body_reader: {QuantumBillingWeb.RawBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug :forget_business
  plug QuantumBillingWeb.Router

  # Bandit serves every request on a keep-alive connection from one process, so
  # the business chosen for the last request would otherwise still be set for
  # this one — a webhook arriving after a page load would run in that page's
  # business. Each request starts with none; the router chooses again.
  #
  # Whatever was set before is put back once the response is sent. In
  # production that is only the previous request's choice, cleared again by the
  # next one; in a test, which calls the endpoint in its own process, it is the
  # test's business, which the test goes on querying in.
  defp forget_business(conn, _opts) do
    previous = QuantumBilling.Repo.business()
    QuantumBilling.Repo.put_business(nil)

    register_before_send(conn, fn conn ->
      QuantumBilling.Repo.put_business(previous)
      conn
    end)
  end
end
