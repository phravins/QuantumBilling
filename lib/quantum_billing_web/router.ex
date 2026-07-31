defmodule QuantumBillingWeb.Router do
  use QuantumBillingWeb, :router

  import QuantumBillingWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {QuantumBillingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public legal documents — must stay reachable while signed out, since the
  # sign-in and sign-up screens link to them.
  scope "/", QuantumBillingWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{QuantumBillingWeb.UserAuth, :mount_current_scope}] do
      live "/terms", TermsLive, :index
      live "/privacy", PrivacyLive, :index
    end
  end

  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :app,
      on_mount: [{QuantumBillingWeb.UserAuth, :require_authenticated}] do
      live "/", DashboardLive, :index
      live "/dashboard", DashboardLive, :index
      live "/invoices", InvoicesLive, :index
      live "/clients", ClientsLive, :index
      live "/clients/new", ClientNewLive, :new
      live "/e-way-bills", EWayBillsLive, :index
      live "/e-way-bills/new", EWayBillNewLive, :index
      live "/reports", ReportsLive, :index
      live "/compliance", ComplianceLive, :index
      live "/settings", SettingsLive, :index
      # The open section lives in the URL so a panel can be linked to directly
      # and survives a reload.
      live "/settings/:section", SettingsLive, :section
    end

    # Outside the live_session above: that block takes only `live` routes.
    get "/reports/export", ReportsController, :export
  end

  # Other scopes may use custom stacks.
  # scope "/api", QuantumBillingWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:quantum_billing, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: QuantumBillingWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{QuantumBillingWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", QuantumBillingWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{QuantumBillingWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    get "/users/confirm/:token", UserConfirmationController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Must stay the last scope in this file. Phoenix matches routes in definition
  # order, so anything declared below this would be unreachable.
  #
  # Catching unknown paths here means they render the branded 404 instead of
  # raising Phoenix.Router.NoRouteError. That matters in development, where the
  # debug error page answers an unrecognised URL with a table of every route in
  # the application. Genuine exceptions still reach the debug page with their
  # stacktrace, so this costs nothing while debugging.
  scope "/", QuantumBillingWeb do
    pipe_through :browser

    match :*, "/*path", PageController, :not_found
  end
end
