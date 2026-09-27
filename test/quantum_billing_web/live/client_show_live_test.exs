defmodule QuantumBillingWeb.ClientShowLiveTest do
  @moduledoc """
  The client detail page the eye icon on the Clients list now opens.

  The assertions about invoice history are scoped to `#client-invoice-history`
  and to the `#client-invoice-<id>` rows rather than made against the rendered
  document. The client's own name and each invoice number are printed in the
  header, the tiles and the notification bell as well, so a bare `html =~`
  would be satisfied by a page whose history table had quietly stopped
  filtering — which is the one thing most of these tests exist to rule out.

  `async: false` because several of them create invoices, which broadcast, and
  the page is subscribed to that topic.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices

  setup :register_and_log_in_user

  setup do
    {:ok, client} =
      Clients.create_client(%{
        "client_type" => "Registered Business",
        "name" => "Acme Traders",
        "gstin" => "27AABCA1234A1Z5",
        "pan" => "AABCA1234A",
        "email" => "billing@acme.in",
        "phone" => "9876543210",
        "billing_line1" => "123 Business Park",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400093",
        "credit_limit" => "250000",
        "payment_terms_days" => "45"
      })

    # No GSTIN, no PAN and no email: the shape that exercises the dash.
    {:ok, other} =
      Clients.create_client(%{
        "client_type" => "Consumer",
        "name" => "Walk-in Buyer",
        "phone" => "9000000000",
        "billing_line1" => "Shop 2",
        "billing_city" => "Pune",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "411001"
      })

    %{client: client, other: other}
  end

  defp invoice_for(client, over \\ %{}) do
    {:ok, invoice} =
      Invoices.create_invoice(
        Map.merge(
          %{
            "client_id" => client.id,
            "client_name" => client.name,
            "client_gstin" => client.gstin,
            "invoice_date" => "2024-05-28",
            "place_of_supply" => "Maharashtra (27)",
            "items" => %{
              "0" => %{
                "description" => "Web Development Services",
                "quantity" => "1",
                "unit" => "Nos",
                "rate" => "50000",
                "tax_rate" => "18",
                "position" => "0"
              }
            }
          },
          over
        )
      )

    invoice
  end

  describe "the record" do
    test "renders the client's own details", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, "#client-name", "Acme Traders")
      assert has_element?(view, "#client-identity", "27AABCA1234A1Z5")
      assert has_element?(view, "#client-identity", "AABCA1234A")
      assert has_element?(view, "#client-contact", "billing@acme.in")
      assert has_element?(view, "#client-contact", "+91 9876543210")
      assert has_element?(view, "#client-addresses", "123 Business Park")
    end

    test "an unfilled field reads as a dash, not as an empty row", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{other.id}")

      assert has_element?(view, "#client-identity", "—")
    end

    test "shipping that follows billing says so rather than printing a blank", %{
      conn: conn,
      client: client
    } do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, "#client-addresses", "Same as the billing address.")
    end

    test "the tiles carry the stored terms", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, "#client-payment-terms", "45 days")
      assert has_element?(view, "#client-credit-limit", "2,50,000.00")
    end

    test "the header links to the edit form and to the full invoice list", %{
      conn: conn,
      client: client
    } do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, ~s{#client-edit-link[href="/clients/#{client.id}/edit"]})
      assert has_element?(view, "#client-invoices-link")
    end

    test "a stale id is redirected rather than raised", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/clients", flash: flash}}} =
               live(conn, ~p"/clients/0")

      assert flash["error"] =~ "no longer exists"
    end

    test "requires authentication", %{client: client} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/clients/#{client.id}")
    end
  end

  describe "the invoice history" do
    test "shows an empty state before there are any", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, "#client-invoice-history", "No invoices for this client yet")
    end

    test "lists this client's invoices", %{conn: conn, client: client} do
      invoice = invoice_for(client)

      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, "#client-invoice-#{invoice.id}", invoice.invoice_number)
      refute has_element?(view, "#client-invoice-history", "No invoices for this client yet")
    end

    # The whole point of the page. A history that shows everybody's invoices is
    # the same defect as an eye icon that opens the wrong screen.
    test "does not list another client's invoices", %{conn: conn, client: client, other: other} do
      mine = invoice_for(client)
      theirs = invoice_for(other)

      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, "#client-invoice-#{mine.id}")
      refute has_element?(view, "#client-invoice-#{theirs.id}")
    end

    # `client_id` is optional — the invoice form's name field can be filled
    # without ever touching the client picker — so keying the history on the
    # foreign key alone would show a real client an empty page.
    test "includes an invoice that carries the name but no client_id", %{
      conn: conn,
      client: client
    } do
      typed = invoice_for(client, %{"client_id" => nil})
      assert is_nil(typed.client_id)

      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, "#client-invoice-#{typed.id}")
    end

    # The other half of that rule: a name match must never override an explicit
    # link, or two clients sharing a name would each claim the other's work.
    test "an invoice linked to another client is not claimed by name", %{
      conn: conn,
      client: client,
      other: other
    } do
      # Same name on the invoice, different client behind it.
      theirs = invoice_for(other, %{"client_name" => client.name})

      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      refute has_element?(view, "#client-invoice-#{theirs.id}")
    end

    test "each row opens the invoice", %{conn: conn, client: client} do
      invoice = invoice_for(client)

      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(
               view,
               ~s{#client-invoice-#{invoice.id} a[href="/invoices/#{invoice.id}"]}
             )
    end

    # Against its own tile rather than the row of four: the credit limit beside
    # it renders "2,50,000.00", so a count asserted over the whole summary
    # block would be satisfied by a digit belonging to another figure.
    test "the invoice count tile follows the history", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")
      assert has_element?(view, "#client-invoice-count", "0")

      invoice_for(client)
      invoice_for(client)

      assert has_element?(view, "#client-invoice-count", "2")
      refute has_element?(view, "#client-invoice-count", "0")
    end

    test "an invoice raised elsewhere appears without a reload", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")
      assert has_element?(view, "#client-invoice-history", "No invoices for this client yet")

      invoice = invoice_for(client)

      assert has_element?(view, "#client-invoice-#{invoice.id}")
    end

    test "pages once there are more than fit", %{conn: conn, client: client} do
      invoices = for _ <- 1..12, do: invoice_for(client)

      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      assert has_element?(view, ~s{[aria-label="Page 1 of 2"]})

      render_click(view, "paginate", %{"page" => "2"})

      # Newest first, so the two oldest are the ones on the second page.
      [oldest, next | _] = invoices

      assert has_element?(view, "#client-invoice-#{oldest.id}")
      assert has_element?(view, "#client-invoice-#{next.id}")
      refute has_element?(view, "#client-invoice-#{List.last(invoices).id}")
    end

    test "a page number that is not one is ignored", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      render_click(view, "paginate", %{"page" => "nonsense"})

      assert has_element?(view, "#client-invoice-history")
    end
  end

  describe "the status control" do
    test "writes the new status and says so", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      html = render_click(view, "set_status", %{"status" => "Blocked"})

      assert html =~ "is now blocked"
      assert Clients.get_client(client.id).status == "Blocked"
    end

    test "a status outside the allowlist is ignored", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      render_click(view, "set_status", %{"status" => "Exempt From Tax"})

      assert Clients.get_client(client.id).status == "Active"
    end
  end

  describe "live updates" do
    test "an edit in another window is reflected here", %{conn: conn, client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      {:ok, _updated} = Clients.update_client(client, %{"name" => "Acme Traders Pvt Ltd"})

      assert has_element?(view, "#client-name", "Acme Traders Pvt Ltd")
    end

    # The topic carries every client in the business. Overwriting the record on
    # somebody else's save would show the wrong customer under this URL.
    test "another client's edit leaves this page alone", %{
      conn: conn,
      client: client,
      other: other
    } do
      {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}")

      {:ok, _updated} = Clients.update_client(other, %{"name" => "Somebody Else Entirely"})

      assert has_element?(view, "#client-name", "Acme Traders")
      refute has_element?(view, "#client-name", "Somebody Else Entirely")
    end
  end
end
