defmodule QuantumBillingWeb.Plugs.RecordExport do
  @moduledoc """
  Counts a data export by the signed-in user, for
  `QuantumBilling.SecurityAlerts.exported/3`: a full backup always tells the
  owners, and a burst of other exports by one person does.

      plug QuantumBillingWeb.Plugs.RecordExport, "GSTR-1" when action in [:export_gstr1]
  """

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.SecurityAlerts

  def init(kind), do: kind

  def call(%{assigns: %{current_scope: %Scope{business: business, user: user}}} = conn, kind)
      when not is_nil(business) and not is_nil(user) do
    SecurityAlerts.exported(business, user, kind)
    conn
  end

  def call(conn, _kind), do: conn
end
