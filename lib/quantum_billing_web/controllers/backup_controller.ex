defmodule QuantumBillingWeb.BackupController do
  @moduledoc "Downloads the business data as JSON, streamed in chunks from a database cursor."
  use QuantumBillingWeb, :controller

  plug QuantumBillingWeb.Plugs.RecordExport, :backup when action in [:download]

  alias QuantumBilling.Backup

  def download(conn, _params) do
    filename = "quantumbilling-backup-#{Date.utc_today()}.json"

    conn =
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_chunked(200)

    {:ok, conn} =
      Backup.stream_json(
        fn data, conn ->
          case chunk(conn, IO.iodata_to_binary(data)) do
            {:ok, conn} -> conn
            # The browser went away mid-download.
            {:error, :closed} -> throw({:closed, conn})
          end
        end,
        conn
      )

    conn
  catch
    {:closed, conn} -> conn
  end
end
