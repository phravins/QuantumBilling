defmodule QuantumBillingWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :quantum_billing

  @session_options [
    store: :cookie,
    key: "_quantum_billing_key",
    signing_salt: "QEN7M6qy",
    same_site: "Lax"
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
  plug QuantumBillingWeb.Router
end
