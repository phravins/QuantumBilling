defmodule QuantumBillingWeb.ClientsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders the page shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ "Clients"
  end

  test "keeps the toolbar available", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-search")
    assert html =~ "All Status"
  end

  test "shows an empty state rather than a bare table", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ "No clients yet"
    assert html =~ "Customers you invoice will appear here."
    refute html =~ "entries"
  end

  test "distinguishes an empty account from an empty search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    html = view |> form("#clients-search", %{"q" => "anything"}) |> render_change()

    assert html =~ "No clients match these filters"
  end

  test "serves no sample records", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    refute html =~ "V2V Technologies"
    refute html =~ "Insta Capital"
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/clients")
  end

  test "the Add New Client button links to the form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/clients")

    assert html =~ ~s(href="/clients/new")
  end

  describe "with clients in the database" do
    setup do
      {:ok, registered} =
        QuantumBilling.Clients.create_client(%{
          "client_type" => "Registered Business",
          "name" => "Acme Traders",
          "gstin" => "27AABCA1234A1Z5",
          "email" => "billing@acme.in",
          "phone" => "9876543210",
          "billing_line1" => "123 Business Park",
          "billing_city" => "Mumbai",
          "billing_state" => "Maharashtra (27)",
          "billing_pin" => "400093"
        })

      # No GSTIN and no email.
      {:ok, walk_in} =
        QuantumBilling.Clients.create_client(%{
          "client_type" => "Consumer",
          "name" => "Walk-in Buyer",
          "phone" => "9000000000",
          "billing_line1" => "Shop 2",
          "billing_city" => "Pune",
          "billing_state" => "Maharashtra (27)",
          "billing_pin" => "411001"
        })

      # Not :registered — ExUnit reserves that context key.
      %{business_client: registered, walk_in: walk_in}
    end

    test "a saved client appears in the table", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/clients")

      assert html =~ "Acme Traders"
      assert html =~ "27AABCA1234A1Z5"
      assert html =~ "billing@acme.in"
      assert html =~ "Walk-in Buyer"
      refute html =~ "No clients yet"
    end

    test "search finds a client by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = view |> form("#clients-search", %{"q" => "Acme"}) |> render_change()

      assert html =~ "Acme Traders"
      refute html =~ "Walk-in Buyer"
    end

    test "search does not crash on a client with no GSTIN or email", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = view |> form("#clients-search", %{"q" => "walk"}) |> render_change()

      assert html =~ "Walk-in Buyer"
      refute html =~ "Acme Traders"
    end

    test "search by GSTIN still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = view |> form("#clients-search", %{"q" => "27AABCA"}) |> render_change()

      assert html =~ "Acme Traders"
      refute html =~ "Walk-in Buyer"
    end

    test "sorting by name works over real rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = render_click(view, "sort", %{"field" => "name"})

      assert html =~ "Acme Traders"
      assert html =~ "Walk-in Buyer"
    end

    test "the row menu links to the client's own edit page", %{
      conn: conn,
      business_client: client
    } do
      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(
               view,
               ~s{#client-#{client.id} a[href="/clients/#{client.id}/edit"]}
             )
    end

    # The eye opens the client; the menu has "View invoices".
    test "the eye opens the client", %{conn: conn, business_client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(view, ~s{#view-client-#{client.id}[href="/clients/#{client.id}"]})
    end

    test "the menu still offers that client's invoices", %{conn: conn, business_client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      assert has_element?(
               view,
               ~s{#client-#{client.id} a[href="/invoices?q=#{URI.encode_www_form(client.name)}"]}
             )
    end

    test "setting a status writes it and says so", %{conn: conn, business_client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = render_click(view, "set_status", %{"id" => client.id, "status" => "Blocked"})

      assert html =~ "is now blocked"
      assert QuantumBilling.Clients.get_client(client.id).status == "Blocked"
    end

    test "a status outside the allowlist is ignored", %{conn: conn, business_client: client} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      render_click(view, "set_status", %{"id" => client.id, "status" => "Exempt From Tax"})

      assert QuantumBilling.Clients.get_client(client.id).status == "Active"
    end

    test "a client deleted elsewhere is reported, not raised", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients")

      html = render_click(view, "set_status", %{"id" => 0, "status" => "Blocked"})

      assert html =~ "no longer exists"
    end

    # The bin sits in the row itself, beside the eye and the menu, rather than
    # inside the menu — and its confirmation says where the client is going.
    test "every row carries a bin button", %{
      conn: conn,
      business_client: client,
      walk_in: walk_in
    } do
      {:ok, view, _html} = live(conn, ~p"/clients")

      for row <- [client, walk_in] do
        assert has_element?(
                 view,
                 ~s|#client-#{row.id} button#client-delete-#{row.id}[data-confirm*="Bin"]|
               )

        refute has_element?(view, "#client-#{row.id} ul #client-delete-#{row.id}")
      end
    end

    test "the bin button moves the client to the Bin", %{
      conn: conn,
      user: user,
      business_client: client,
      walk_in: walk_in
    } do
      {:ok, view, _html} = live(conn, ~p"/clients")

      view |> element("#client-delete-#{client.id}") |> render_click()

      refute has_element?(view, "#client-#{client.id}")
      assert has_element?(view, "#client-#{walk_in.id}")
      assert has_element?(view, "#flash-info", "moved to the Bin")

      # Off the list, not out of the database.
      assert QuantumBilling.Clients.get_client(client.id) == nil
      assert QuantumBilling.Clients.get_deleted_client(client.id).name == "Acme Traders"

      assert Enum.any?(QuantumBilling.Audit.list_audit_logs(), fn log ->
               log.action == "bin_client" and log.user_id == user.id and
                 log.resource_id == to_string(client.id)
             end)

      {:ok, bin, _html} = live(conn, ~p"/bin")
      assert has_element?(bin, "#bin-client-#{client.id}", "Acme Traders")
    end

    test "a client binned in another window leaves this list", %{
      conn: conn,
      business_client: client
    } do
      {:ok, view, _html} = live(conn, ~p"/clients")
      assert has_element?(view, "#client-#{client.id}")

      {:ok, _binned} = QuantumBilling.Clients.delete_client(client)

      # `render/1` is a call into the view, so it is answered after the
      # broadcast ahead of it in the mailbox has been handled.
      render(view)

      refute has_element?(view, "#client-#{client.id}")
    end

    test "deleting a client that is already gone is reported, not raised", %{
      conn: conn,
      business_client: client
    } do
      {:ok, view, _html} = live(conn, ~p"/clients")

      {:ok, _binned} = QuantumBilling.Clients.delete_client(client)

      render_click(view, "delete", %{"id" => to_string(client.id)})
      assert has_element?(view, "#flash-error", "no longer exists")

      render_click(view, "delete", %{"id" => "not-an-id"})
      assert has_element?(view, "#flash-error", "no longer exists")
    end
  end
end
