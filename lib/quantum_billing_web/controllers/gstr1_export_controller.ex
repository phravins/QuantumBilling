defmodule QuantumBillingWeb.GSTR1ExportController do
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Compliance.GSTNExporter

  @doc """
  Serves a downloadable GSTR-1 JSON file.
  """
  def export_gstr1(conn, params) do
    period = params["period"] || "032026"
    gstn_json = GSTNExporter.generate_gstr1_json(period)
    filename = "GSTR1_#{gstn_json["gstin"]}_#{period}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, Jason.encode!(gstn_json, pretty: true))
  end
end
