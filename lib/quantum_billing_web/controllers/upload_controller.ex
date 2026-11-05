defmodule QuantumBillingWeb.UploadController do
  @moduledoc """
  Serves uploaded files to signed-in members of the business that owns them
  (its logo or a recorded design asset). Everyone else gets the same 403
  whether or not the file exists.

  Headers keep the file inert on this origin: `Content-Disposition: attachment`,
  a `default-src 'none'; sandbox` CSP and `nosniff`.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.DesignAssets
  alias QuantumBilling.Uploads
  alias QuantumBillingWeb.UserAuth

  def show(conn, %{"file" => name}) do
    with %{business: %{}} <- conn.assigns.current_scope,
         true <- DesignAssets.owned?("/uploads/" <> name),
         {:ok, file, content_type} <- Uploads.locate(name) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("content-disposition", "attachment")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("x-content-type-options", "nosniff")
      # Not `public`: a shared cache must not hand this to the next person.
      |> put_resp_header("cache-control", "private, max-age=300")
      |> send_file(200, file)
    else
      _not_theirs -> UserAuth.forbidden(conn)
    end
  end
end
