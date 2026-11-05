defmodule QuantumBillingWeb.GSTR1ExportController do
  @moduledoc """
  Downloads the GSTR-1 JSON for one return period (`MMYYYY`), defaulting to last month.
  The period is validated first, since it picks the invoices and the filename.
  """
  use QuantumBillingWeb, :controller

  plug QuantumBillingWeb.Plugs.RecordExport, "GSTR-1 export" when action in [:export_gstr1]

  alias QuantumBilling.Compliance.GSTNExporter

  def export_gstr1(conn, params) do
    period = param(params, "period") || GSTNExporter.default_period()

    case GSTNExporter.generate_gstr1_json(period) do
      {:ok, payload} ->
        filename = "GSTR1_#{payload["gstin"]}_#{period}.json"

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, Jason.encode!(payload, pretty: true))

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/compliance")
    end
  end

  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing_or_nested -> nil
    end
  end
end
