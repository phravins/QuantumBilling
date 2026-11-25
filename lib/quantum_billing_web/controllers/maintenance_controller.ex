defmodule QuantumBillingWeb.MaintenanceController do
  @moduledoc """
  The page maintenance mode sends everyone to, except super admins. Answers
  503 while maintenance is on, and sends visitors home once it is over.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.InstallationSettings

  def show(conn, _params) do
    if InstallationSettings.maintenance?() do
      conn
      |> put_status(:service_unavailable)
      |> put_resp_header("retry-after", "300")
      |> put_layout(false)
      |> render(:show, admin?: Scope.admin?(conn.assigns[:current_scope]))
    else
      redirect(conn, to: ~p"/")
    end
  end
end
