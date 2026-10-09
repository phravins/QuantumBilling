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

  # Public legal documents — must stay reachable while signed out, since the
  # sign-in and sign-up screens link to them.
  scope "/", QuantumBillingWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{QuantumBillingWeb.UserAuth, :mount_current_scope}] do
      live "/terms", TermsLive, :index
      live "/privacy", PrivacyLive, :index
      live "/pay/:token", PublicInvoiceLive, :show
    end

    # Outside the live_session above, which takes only `live` routes. The
    # customer's copy of the document, addressed by the same token.
    get "/pay/:token/pdf", InvoicePdfController, :public
  end

  # Owner-only. These are the things that administer the installation rather
  # than use it: the accounts, and the full database export.
  #
  # Every account on this installation shares one dataset — there is no
  # per-user scoping on invoices or clients, by design, because the
  # application bills for one business. So an account is access to the books,
  # and handing out accounts, plus taking a copy of everything, belongs to
  # whoever owns the business rather than to everyone who can sign in.
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

  # Declared before the scope below: Phoenix matches in definition order, and
  # "/settings/:section" there would otherwise swallow "/settings/team".
  scope "/", QuantumBillingWeb do
    pipe_through [:browser, :require_authenticated_user]

    # `NotificationsHook` after `:require_authenticated`, and never before:
    # it reads the feed out of the database, and an unauthenticated visitor must
    # be halted at the first hook rather than have a query run for them. It is
    # on the `live_session` rather than on the individual pages because the bell
    # is drawn by `Layouts.app`, which every page in this block uses.
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
      # In this live_session because the Bin lists business records and can
      # destroy them for good: it needs the login check, and `Layouts.app`
      # needs the scope and the notification feed the hooks above assign.
      live "/bin", BinLive, :index
      live "/settings/audit-logs", AuditLogsLive, :index
      live "/settings", SettingsLive, :index
      # The open section lives in the URL so a panel can be linked to directly
      # and survives a reload.
      live "/settings/:section", SettingsLive, :section
      # The design pad is reached from Settings > Customization but is its own
      # page: it needs three columns and autosaves per interaction, neither of
      # which fits the settings shell's single form and header Save button.
      live "/invoice-templates/:id", InvoiceTemplateDesignLive, :design
    end

    # Outside the live_session above: that block takes only `live` routes.
    get "/reports/export", ReportsController, :export
    get "/reports/gstr1/export", GSTR1ExportController, :export_gstr1
    get "/invoices/:id/pdf", InvoicePdfController, :show
    get "/invoices/:id/pdf/download", InvoicePdfController, :download
    # The official e-way bill, Form GST EWB-01. Same scope and the same
    # `:require_authenticated_user` pipeline as the other document routes, and
    # outside `live_session :app` because that block takes only `live` routes.
    # The list page's Export button. Same scope and pipeline as the reports
    # export above, and above the `:id` routes only for readability — the paths
    # differ in segment count, so they cannot collide.
    get "/e-way-bills/export", EWayBillExportController, :export
    get "/e-way-bills/:id/print", EWayBillPdfController, :show
    get "/e-way-bills/:id/print/download", EWayBillPdfController, :download
    get "/invoices/:id/e-invoice.xml", EInvoiceController, :show
  end

  # Deliberately on `:api` and not `:browser`: a container probe must not need
  # a session, a CSRF token or the security-policy plug, and above all must not
  # have to load the current scope out of the database it is checking. It also
  # has to sit above the catch-all at the bottom of this file, which would
  # otherwise answer /health with the branded 404 page.
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

    # The same pair as `live_session :app` above, for the same reason: the
    # account settings screen draws `Layouts.app`, so it draws the bell, and a
    # page that renders the bell without the feed assigned would fall back to an
    # empty one on a screen where the rest of the application has it filled.
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
      # Reaching these while signed out is the whole point, so they belong in
      # `:current_user` rather than `:require_authenticated_user`: someone who
      # has forgotten their password cannot be asked to sign in first.
      live "/users/forgot-password", UserLive.ForgotPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
      # The second step of signing in. Reachable only with a pending attempt in
      # the session, which the LiveView checks on mount.
      live "/users/two-factor", UserLive.TwoFactorChallenge, :new
    end

    get "/users/confirm/:token", UserConfirmationController, :confirm
    post "/users/log-in", UserSessionController, :create
    post "/users/two-factor", UserSessionController, :verify_two_factor
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
