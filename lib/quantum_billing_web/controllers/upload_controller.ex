defmodule QuantumBillingWeb.UploadController do
  @moduledoc """
  Serves uploaded files to the people they belong to.

  A file goes out only to someone signed in, in the business whose settings point
  at it. Everyone else gets the same Forbidden page whether or not the file
  exists, so the answer does not reveal which names are real.

  Customers on a public invoice page never come through here: that page carries
  the logo inline.

  The headers make the file safe on this origin:

    * `Content-Disposition: attachment` downloads the file when it is opened as a
      page. An `<img src>` is unaffected.

    * `default-src 'none'; sandbox` leaves it unable to run script or load
      anything if a browser does render it.

    * `X-Content-Type-Options: nosniff` holds the browser to the declared type.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Settings
  alias QuantumBilling.Uploads
  alias QuantumBillingWeb.UserAuth

  def show(conn, %{"file" => name}) do
    with %{business: %{}} <- conn.assigns.current_scope,
         true <- Settings.get_organization().doc_logo_path == "/uploads/" <> name,
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
