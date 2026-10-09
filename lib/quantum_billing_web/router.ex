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
    plug QuantumBillingWeb.Plugs.EnforceSecurityPolicies
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public legal pages, linked from sign-in and sign-up.
  scope "/", QuantumBillingWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{QuantumBillingWeb.UserAuth, :mount_current_scope}] do
      live "/terms", TermsLive, :index
      live "/privacy", PrivacyLive, :index
      live "/pay/:token", PublicInvoiceLive, :show
    end

    # Outside the live_session, which takes only live routes.
    get "/pay/:token/pdf", InvoicePdfController, :public
  end

  # Owner-only: account administration and the full export.
  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user, :require_owner]

    live_session :owner,
      on_mount: [
        {QuantumBillingWeb.UserAuth, :require_authenticated},
        {QuantumBillingWeb.UserAuth, :require_owner}
      ] do
      live "/settings/team", SettingsLive.Team, :index
    end

    get "/settings/backup/download", BackupController, :download
  end

  # Before "/settings/:section", which would otherwise match "/settings/team".
  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user]

    # NotificationsHook must run after :require_authenticated.
    live_session :app,
      on_mount: [
        {QuantumBillingWeb.UserAuth, :require_authenticated},
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
      live "/reports", ReportsLive, :index
      live "/compliance", ComplianceLive, :index
      live "/recurring", RecurringLive, :index
      live "/bin", BinLive, :index
      live "/settings/audit-logs", AuditLogsLive, :index
      live "/settings", SettingsLive, :index
      live "/settings/:section", SettingsLive, :section
      live "/invoice-templates/:id", InvoiceTemplateDesignLive, :design
    end

    # Outside the live_session: it takes only live routes.
    get "/reports/export", ReportsController, :export
    get "/reports/gstr1/export", GSTR1ExportController, :export_gstr1
    get "/invoices/:id/pdf", InvoicePdfController, :show
    get "/invoices/:id/pdf/download", InvoicePdfController, :download
    get "/e-way-bills/export", EWayBillExportController, :export
    get "/e-way-bills/:id/print", EWayBillPdfController, :show
    get "/e-way-bills/:id/print/download", EWayBillPdfController, :download
    get "/invoices/:id/e-invoice.xml", EInvoiceController, :show
  end

  # On :api, not :browser: a probe needs no session. Must stay above the catch-all.
  scope "/", QuantumBillingWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/api", QuantumBillingWeb do
    pipe_through :api

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
