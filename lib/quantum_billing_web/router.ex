defmodule QuantumBillingWeb.Router do
  use QuantumBillingWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {QuantumBillingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", QuantumBillingWeb do
    pipe_through :browser

    live_session :app do
      live "/", DashboardLive, :index
      live "/dashboard", DashboardLive, :index
      live "/invoices", PlaceholderLive, :invoices
      live "/clients", PlaceholderLive, :clients
      live "/e-way-bills", PlaceholderLive, :e_way_bills
      live "/reports", PlaceholderLive, :reports
      live "/compliance", PlaceholderLive, :compliance
      live "/settings", PlaceholderLive, :settings
    end
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
end
