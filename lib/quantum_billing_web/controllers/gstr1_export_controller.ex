defmodule QuantumBillingWeb.GSTR1ExportController do
  @moduledoc """
  Downloads the GSTR-1 JSON for one return period.

  The period comes from the query string and is validated before anything else
  happens: it selects the invoices that go in the file, and it is interpolated
  into the `content-disposition` header, so an unchecked value picks both the
  contents and the name of a statutory filing.

  With no period given it defaults to the month just gone, which is the one a
  return is normally filed for. It used to default to a hardcoded `"032026"`,
  and the page linked here without a period at all — so every download claimed
  to be March 2026 whatever month it was.
  """
  use QuantumBillingWeb, :controller

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
