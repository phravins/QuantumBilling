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
    plug QuantumBillingWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
    plug :fetch_current_business
    plug QuantumBillingWeb.Plugs.EnforceSecurityPolicies
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The external API. No session, no cookies, no CSRF token and no CORS: it is
  # for server-to-server calls with a bearer key, and a browser has no business
  # making them. Order matters — https before the key is looked at, the key
  # before the rate limit (which is per key), and the scope check per action in
  # each controller.
  pipeline :api_v1 do
    plug :accepts, ["json"]
    plug QuantumBillingWeb.Plugs.ApiRequireHttps
    plug QuantumBillingWeb.Plugs.ApiAuth
    plug QuantumBillingWeb.Plugs.ApiRateLimit
  end

  # Calendar apps send no cookies and ask for `text/calendar`, so this has neither
  # a session nor the `accepts` check of `:api`. The token in the URL is the access
  # control, and the rate limit makes guessing it pointless.
  pipeline :calendar_feed do
    plug QuantumBillingWeb.Plugs.CalendarFeedRateLimit
  end

  # Public legal pages, linked from sign-in and sign-up.
  scope "/", QuantumBillingWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{QuantumBillingWeb.UserAuth, :mount_current_scope}] do
      live "/terms", TermsLive, :index
      live "/privacy", PrivacyLive, :index
      # The slug names the business the invoice belongs to. `/pay/:token`
      # links were handed out before there were several, and lead to the first.
      live "/p/:slug/:token", PublicInvoiceLive, :show
      live "/pay/:token", PublicInvoiceLive, :show
    end

    # Outside the live_session, which takes only live routes.
    get "/p/:slug/:token/pdf", InvoicePdfController, :public
    get "/pay/:token/pdf", InvoicePdfController, :public
  end

  # Owner-only: account administration and the full export.
  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user, :require_business, :require_owner]

    live_session :owner,
      on_mount: [
        {QuantumBillingWeb.UserAuth, :require_authenticated},
        {QuantumBillingWeb.UserAuth, :require_business},
        {QuantumBillingWeb.UserAuth, :require_owner},
        {QuantumBillingWeb.NotificationsHook, :default}
      ] do
      live "/settings/team", SettingsLive.Team, :index
      # Keys reach the books without anyone signing in, so issuing them is the
      # owner's call, like handing out accounts.
      live "/settings/api-keys", SettingsLive.ApiKeys, :index
    end
  end

  # Controllers, because they write the OAuth state to the session and redirect
  # off-site. Connecting a calendar is an owner's call inside a chosen business.
  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user, :require_business, :require_owner]

    get "/integrations/google/connect", GoogleCalendarController, :connect
    get "/integrations/google/callback", GoogleCalendarController, :callback
  end

  # Files get the Forbidden page instead of a redirect when nobody is signed in.
  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_user_or_forbid, :require_business, :require_owner]

    get "/settings/backup/download", BackupController, :download
  end

  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_user_or_forbid, :require_business]

    get "/reports/export", ReportsController, :export
    get "/reports/gstr1/export", GSTR1ExportController, :export_gstr1
    get "/invoices/:id/pdf", InvoicePdfController, :show
    get "/invoices/:id/pdf/download", InvoicePdfController, :download
    get "/e-way-bills/export", EWayBillExportController, :export
    get "/e-way-bills/:id/print", EWayBillPdfController, :show
    get "/e-way-bills/:id/print/download", EWayBillPdfController, :download
    get "/invoices/:id/e-invoice.xml", EInvoiceController, :show
  end

  # Decides for itself: the answer depends on whose logo the file is.
  scope "/", QuantumBillingWeb do
    pipe_through :browser

    get "/uploads/:file", UploadController, :show
  end

  # Before "/settings/:section", which would otherwise match "/settings/team".
  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user, :require_business]

    # NotificationsHook must run after :require_business: the feed is the business's.
    live_session :app,
      on_mount: [
        {QuantumBillingWeb.UserAuth, :require_authenticated},
        {QuantumBillingWeb.UserAuth, :require_business},
        {QuantumBillingWeb.NotificationsHook, :default}
      ] do
      live "/", DashboardLive, :index
      live "/dashboard", DashboardLive, :index
      live "/invoices", InvoicesLive, :index
      live "/invoices/new", InvoiceNewLive, :new
      # Before "/invoices/:id", or "new" and "<id>/edit" would both match it.
      live "/invoices/:id/edit", InvoiceNewLive, :edit
      live "/invoices/:id", InvoiceShowLive, :show
      live "/clients", ClientsLive, :index
      live "/clients/new", ClientNewLive, :new
      # Before "/clients/:id", or "new" and "<id>/edit" would both match it.
      live "/clients/:id/edit", ClientNewLive, :edit
      live "/clients/:id", ClientShowLive, :show
      live "/e-way-bills", EWayBillsLive, :index
      live "/e-way-bills/new", EWayBillNewLive, :index
      live "/hsn-finder", HsnFinderLive, :index
      live "/compliance", ComplianceLive, :index
      live "/recurring", RecurringLive, :index
      live "/bin", BinLive, :index
      live "/settings/audit-logs", AuditLogsLive, :index
      live "/settings", SettingsLive, :index
      live "/settings/:section", SettingsLive, :section
      live "/invoice-templates/:id", InvoiceTemplateDesignLive, :design
    end
  end

  # On :api, not :browser: a probe needs no session. Must stay above the catch-all.
  scope "/", QuantumBillingWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/", QuantumBillingWeb do
    pipe_through :calendar_feed

    get "/calendar/:slug/:token", CalendarFeedController, :show
  end

  # Before the "/api" scope below and the catch-all at the bottom, so that
  # every /api/v1 path — including ones that do not exist — is answered in
  # JSON, and only after the key has been checked.
  scope "/api/v1", QuantumBillingWeb.API.V1 do
    pipe_through :api_v1

    get "/me", MeController, :show
    get "/invoices", InvoiceController, :index
    post "/invoices", InvoiceController, :create
    get "/invoices/:id", InvoiceController, :show
    get "/clients", ClientController, :index
    post "/clients", ClientController, :create
    get "/clients/:id", ClientController, :show
    get "/e-way-bills", EWayBillController, :index
    get "/e-way-bills/:id", EWayBillController, :show

    match :*, "/*path", FallbackController, :not_found
  end

  scope "/api", QuantumBillingWeb do
    pipe_through :api

    # The slug names the business the payment belongs to; the bare path, which
    # Razorpay dashboards were set up with before, delivers to the first.
    post "/webhooks/razorpay/:slug", PaymentWebhookController, :handle_razorpay
    post "/webhooks/razorpay", PaymentWebhookController, :handle_razorpay
  end

  if Application.compile_env(:quantum_billing, :dev_routes) do
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

    # Same hooks as live_session :app: this page draws the notification bell.
    live_session :require_authenticated_user,
      on_mount: [
        {QuantumBillingWeb.UserAuth, :require_authenticated},
        {QuantumBillingWeb.NotificationsHook, :default}
      ] do
      live "/users/profile", UserLive.Profile, :show
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      # Choosing or creating a business needs a signed-in user but no business yet.
      live "/businesses", BusinessPickerLive, :index
      live "/businesses/new", BusinessNewLive, :new
    end

    post "/users/update-password", UserSessionController, :update_password
    # A controller, not an event: only an HTTP response can write the session.
    post "/businesses/:id/switch", BusinessController, :switch
  end

  scope "/", QuantumBillingWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{QuantumBillingWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/users/forgot-password", UserLive.ForgotPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
      # Requires a pending sign-in in the session.
      live "/users/two-factor", UserLive.TwoFactorChallenge, :new
    end

    get "/users/confirm/:token", UserConfirmationController, :confirm
    post "/users/log-in", UserSessionController, :create
    post "/users/two-factor", UserSessionController, :verify_two_factor
    delete "/users/log-out", UserSessionController, :delete
  end

  # Must stay last: renders the branded 404 for unknown paths.
  scope "/", QuantumBillingWeb do
    pipe_through :browser

    match :*, "/*path", PageController, :not_found
  end
end
