defmodule QuantumBillingWeb.Router do
  use QuantumBillingWeb, :router

  import QuantumBillingWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {QuantumBillingWeb.Layouts, :root}
    plug :protect_from_forgery
    # Extra headers: no framing (older browsers), no device or payment APIs,
    # and an isolated window. The CSP here is only a floor: the next plug
    # replaces it with the nonced policy.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
      "x-frame-options" => "DENY",
      "permissions-policy" =>
        "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()",
      "cross-origin-opener-policy" => "same-origin"
    }

    plug QuantumBillingWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
    plug :fetch_current_business
    plug QuantumBillingWeb.Plugs.EnforceSecurityPolicies
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug QuantumBillingWeb.Plugs.ApiResponseHeaders
  end

  # Server-to-server API with a bearer key: no session, CSRF or CORS.
  # Order matters: https, then the key, then the per-key rate limit.
  pipeline :api_v1 do
    plug :accepts, ["json"]
    plug QuantumBillingWeb.Plugs.ApiResponseHeaders
    plug QuantumBillingWeb.Plugs.ApiRequireHttps
    plug QuantumBillingWeb.Plugs.ApiAuth
    plug QuantumBillingWeb.Plugs.ApiRateLimit
  end

  # Calendar apps send no cookies: the URL token is the access control, rate limited.
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
      # `/pay/:token` is the legacy link, for the first business.
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
        {QuantumBillingWeb.UserAuth, :require_onboarded},
        {QuantumBillingWeb.UserAuth, :require_business},
        {QuantumBillingWeb.UserAuth, :require_owner},
        {QuantumBillingWeb.NotificationsHook, :default}
      ] do
      live "/settings/team", SettingsLive.Team, :index
      live "/settings/api-keys", SettingsLive.ApiKeys, :index
      live "/settings/webhooks", SettingsLive.Webhooks, :index
      live "/settings/data-model", SettingsLive.DataModel, :index
      live "/settings/audit-logs", AuditLogsLive, :index
    end
  end

  # Controllers: they write OAuth state to the session and redirect off-site.
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
    get "/invoice-templates/:id/export", InvoiceTemplateExportController, :export
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
        {QuantumBillingWeb.UserAuth, :require_onboarded},
        {QuantumBillingWeb.UserAuth, :require_business},
        {QuantumBillingWeb.NotificationsHook, :default}
      ] do
      live "/", DashboardLive, :index
      live "/dashboard", DashboardLive, :index
      # The step after BusinessController.switch: needs the business it names.
      live "/businesses/ready", BusinessReadyLive, :show
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

  # Before "/api" and the catch-all, so every /api/v1 path answers JSON after the key check.
  scope "/api/v1", QuantumBillingWeb.API.V1 do
    pipe_through :api_v1

    get "/me", MeController, :show
    get "/invoices", InvoiceController, :index
    post "/invoices", InvoiceController, :create
    get "/invoices/:id", InvoiceController, :show
    post "/invoices/:id/payments", InvoiceController, :record_payment
    post "/invoices/:id/cancel", InvoiceController, :cancel
    post "/invoices/:id/e-invoice", InvoiceController, :register_e_invoice
    post "/invoices/:invoice_id/credit-notes", CreditNoteController, :create
    get "/credit-notes", CreditNoteController, :index
    get "/credit-notes/:id", CreditNoteController, :show
    get "/clients", ClientController, :index
    post "/clients", ClientController, :create
    get "/clients/:id", ClientController, :show
    get "/e-way-bills", EWayBillController, :index
    get "/e-way-bills/:id", EWayBillController, :show

    match :*, "/*path", FallbackController, :not_found
  end

  scope "/api", QuantumBillingWeb do
    pipe_through :api

    # The bare path is legacy and delivers to the first business.
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
      # Signed in, but no business chosen yet.
      live "/onboarding", OnboardingLive, :show
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
