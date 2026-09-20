defmodule QuantumBillingWeb.BackupController do
  @moduledoc """
  Downloads the business data as JSON.

  Sent as chunks straight from a database cursor. Building the file first meant
  holding all of it in memory — a hundred megabytes at fifty thousand invoices
  — and sending nothing at all until half a minute had passed, by which time
  the browser had usually given up.
  """
  use QuantumBillingWeb, :controller

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
            # The browser went away mid-download. Stop reading rather than
            # stream a file nobody is receiving.
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
