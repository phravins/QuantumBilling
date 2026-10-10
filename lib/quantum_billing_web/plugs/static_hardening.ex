defmodule QuantumBillingWeb.Plugs.StaticHardening do
  @moduledoc """
  Makes user-uploaded files safe to serve from this application's own origin.

  `Plug.Static` runs in the endpoint, ahead of the router — so nothing in the
  `:browser` pipeline applies to it, and uploaded files were going out with no
  security headers at all. This sits in front of `Plug.Static` and adds them
  for the one prefix whose contents a user chose.

  Three headers, each doing a different job:

    * `Content-Disposition: attachment` — opening the file as a top-level
      navigation downloads it instead of rendering it. A `<img src>` is
      unaffected, so the logo still displays wherever the application puts it;
      what stops working is sending somebody a link to an uploaded file and
      having the browser treat it as a document on this origin.

    * a `Content-Security-Policy` of its own — `default-src 'none'; sandbox`
      leaves the file unable to run script, load anything or reach the network
      even if a browser does decide to render it.

    * `X-Content-Type-Options: nosniff` — serve it as the declared type or not
      at all, rather than letting the browser decide from the bytes.

  SVG uploads are refused outright now (see `QuantumBilling.Uploads`), which
  is what actually closes that hole. This is the belt to that braces: it
  covers whatever is already on disk from before, and whatever gets added to
  the accepted list later.
  """

  import Plug.Conn

  @hardened_prefixes ["/uploads"]

  def init(opts), do: opts

  def call(conn, _opts) do
    if hardened?(conn.request_path) do
      conn
      |> put_resp_header("content-disposition", "attachment")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("x-content-type-options", "nosniff")
    else
      conn
    end
  end

  defp hardened?(path) when is_binary(path) do
    Enum.any?(@hardened_prefixes, &String.starts_with?(path, &1 <> "/"))
  end

  defp hardened?(_path), do: false
end
