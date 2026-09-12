defmodule QuantumBillingWeb.BackupController do
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Backup

  def download(conn, _params) do
    json_data = Backup.export_json()
    filename = "quantumbilling-backup-#{Date.utc_today()}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, json_data)
  end
end
