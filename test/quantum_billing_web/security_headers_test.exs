defmodule QuantumBillingWeb.SecurityHeadersTest do
  @moduledoc """
  The headers that stand between an injected script and the rest of the
  application.

  There was no Content-Security-Policy at all, and `/uploads` — the one prefix
  whose contents a user chooses — went out with no security headers whatsoever,
  because `Plug.Static` runs in the endpoint, ahead of the router pipeline that
  sets them.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  defp csp(conn) do
    conn |> get_resp_header("content-security-policy") |> List.first()
  end

  describe "the application's pages" do
    test "carry a policy", %{conn: conn} do
      policy = conn |> get(~p"/dashboard") |> csp()

      assert policy =~ "default-src 'self'"
      assert policy =~ "object-src 'none'"
      assert policy =~ "frame-ancestors 'none'"
      assert policy =~ "base-uri 'self'"
      assert policy =~ "form-action 'self'"
    end

    test "allow script only from this origin and one nonce", %{conn: conn} do
      policy = conn |> get(~p"/dashboard") |> csp()

      assert policy =~ "script-src 'self' 'nonce-"
      # The whole point: allowing inline script wholesale would allow every
      # injected one too.
      refute policy =~ "script-src 'self' 'unsafe-inline'"
    end

    test "stamp that nonce on the one inline script, and nowhere else", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")
      html = html_response(conn, 200)

      [policy] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)

      assert html =~ ~s(nonce="#{nonce}")
      # One nonce per response, so a script injected into a stored field
      # cannot carry a valid one.
      assert html |> String.split(~s(nonce="#{nonce}")) |> length() == 2
    end

    test "give a different nonce to every response", %{conn: conn} do
      a = conn |> get(~p"/dashboard") |> csp()
      b = conn |> recycle() |> get(~p"/dashboard") |> csp()

      # A nonce reused across responses is a nonce an attacker can learn from
      # one page and use on the next.
      assert a != b
    end

    test "allow the LiveView socket and inlined image data", %{conn: conn} do
      policy = conn |> get(~p"/dashboard") |> csp()

      # A websocket is a different scheme, so 'self' does not cover it.
      assert policy =~ "connect-src 'self' ws: wss:"
      # The invoice document inlines its logo as a data URI so the printed and
      # emailed copies carry it.
      assert policy =~ "img-src 'self' data:"
    end

    test "every page still renders under the policy", %{conn: conn} do
      # A policy that breaks the application is worse than none, because it
      # gets turned off.
      for path <- [~p"/dashboard", ~p"/invoices", ~p"/clients", ~p"/reports", ~p"/settings"] do
        assert {:ok, _view, _html} = live(conn, path), "#{path} did not mount under the CSP"
      end
    end
  end

  describe "the printable invoice page" do
    setup %{conn: conn} do
      {:ok, client} =
        QuantumBilling.Clients.create_client(%{
          "client_type" => "Unregistered",
          "name" => "Acme Traders",
          "phone" => "9876543210",
          "billing_line1" => "1 Main Street",
          "billing_city" => "Mumbai",
          "billing_state" => "Maharashtra (27)",
          "billing_pin" => "400001"
        })

      {:ok, invoice} =
        QuantumBilling.Invoices.create_invoice(%{
          "client_id" => client.id,
          "client_name" => client.name,
          "invoice_date" => Date.to_iso8601(Date.utc_today()),
          "place_of_supply" => "Maharashtra (27)",
          "items" => %{
            "0" => %{
              "description" => "Consulting",
              "hsn_sac" => "998313",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "5000",
              "tax_rate" => "18"
            }
          }
        })

      %{conn: conn, invoice: invoice}
    end

    test "its auto-print script carries a nonce", %{conn: conn, invoice: invoice} do
      conn = get(conn, ~p"/invoices/#{invoice.id}/pdf")
      html = response(conn, 200)

      [policy] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)

      # The layout is off on this page, so it needs its own nonce or the CSP silently
      # blocks the print script.
      assert html =~ ~s(nonce="#{nonce}")
      assert html =~ "window.print()"
    end

    test "its inline stylesheet is permitted", %{conn: conn, invoice: invoice} do
      conn = get(conn, ~p"/invoices/#{invoice.id}/pdf")
      html = response(conn, 200)

      [policy] = get_resp_header(conn, "content-security-policy")

      # The document uses an inline <style>; see InvoiceDoc.Renderer.
      assert policy =~ "style-src 'self' 'unsafe-inline'"
      assert html =~ "<style"
    end
  end

  describe "uploaded files" do
    setup do
      uploads = Path.join([:code.priv_dir(:quantum_billing), "static", "uploads"])
      File.mkdir_p!(uploads)

      name = "headers-#{System.unique_integer([:positive])}.png"
      path = Path.join(uploads, name)
      File.write!(path, <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
      on_exit(fn -> File.rm(path) end)

      %{name: name}
    end

    test "are served as a download, not as a document on this origin", %{conn: conn, name: name} do
      conn = get(conn, "/uploads/#{name}")

      assert response(conn, 200)

      # Opening one as a top-level navigation downloads it. An <img src> is
      # unaffected, so the logo still displays where the application puts it.
      assert get_resp_header(conn, "content-disposition") == ["attachment"]
    end

    test "are sandboxed and may load nothing of their own", %{conn: conn, name: name} do
      conn = get(conn, "/uploads/#{name}")

      assert get_resp_header(conn, "content-security-policy") == [
               "default-src 'none'; sandbox"
             ]

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "the application's own assets are not hobbled by that", %{conn: conn} do
      conn = get(conn, "/favicon.svg")

      # Only the user-supplied prefix is hardened; the bundle and the icons
      # have to keep working normally.
      assert get_resp_header(conn, "content-disposition") == []
    end
  end
end
