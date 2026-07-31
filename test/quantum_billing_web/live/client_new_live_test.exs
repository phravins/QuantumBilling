defmodule QuantumBillingWeb.ClientNewLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Clients

  setup :register_and_log_in_user

  defp valid_params(overrides \\ %{}) do
    Map.merge(
      %{
        "client_type" => "Registered Business",
        "name" => "Acme Traders Private Limited",
        "gstin" => "27AABCA1234A1Z5",
        "phone" => "9876543210",
        "email" => "billing@acme.in",
        "billing_line1" => "123 Business Park",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400093"
      },
      overrides
    )
  end

  describe "page" do
    test "renders every section from the design", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/clients/new")

      assert html =~ "Add New Client"
      assert html =~ "Basic Information"
      assert html =~ "Contact Information"
      assert html =~ "Billing Address"
      assert html =~ "Same as billing address"
      assert html =~ "Additional Information"
      assert html =~ "Information"
      assert html =~ "Tips"
    end

    test "breadcrumbs back to the list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/clients/new")

      assert html =~ ~s(href="/clients")
      assert html =~ "Cancel"
      assert html =~ "Save Client"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/clients/new")
    end
  end

  describe "the GSTIN field follows the client type" do
    test "is enabled for a registered business", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      view
      |> form("#client-form", %{"client" => %{"client_type" => "Registered Business"}})
      |> render_change()

      # Asserting the attribute, not the string "disabled" — every input carries
      # a `disabled:bg-base-200` class, so a substring check proves nothing.
      refute has_element?(view, "input[name=\"client[gstin]\"][disabled]")
    end

    test "is disabled for a consumer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      html =
        view
        |> form("#client-form", %{"client" => %{"client_type" => "Consumer"}})
        |> render_change()

      assert html =~ "Not applicable to this client type."
      assert has_element?(view, "input[name=\"client[gstin]\"][disabled]")
    end
  end

  describe "shipping address" do
    test "is hidden while it is the same as billing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/clients/new")

      refute html =~ "Shipping Address"
    end

    test "appears when unticked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      html =
        view
        |> form("#client-form", %{"client" => %{"shipping_same_as_billing" => "false"}})
        |> render_change()

      assert html =~ "Shipping Address"
    end
  end

  describe "validation" do
    test "shows an inline error and saves nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      html =
        view
        |> form("#client-form", %{"client" => valid_params(%{"gstin" => "NOPE"})})
        |> render_submit()

      assert html =~ "is not a valid GSTIN"
      assert Clients.list_clients() == []
    end

    test "catches a GSTIN whose state code contradicts the address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      html =
        view
        |> form("#client-form", %{"client" => valid_params(%{"gstin" => "29AABCU9603R1ZM"})})
        |> render_submit()

      assert html =~ "does not match the GSTIN&#39;s state code"
      assert Clients.list_clients() == []
    end

    test "a registered business without a GSTIN is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      html =
        view
        |> form("#client-form", %{"client" => valid_params(%{"gstin" => ""})})
        |> render_submit()

      assert html =~ "is required for a Registered Business"
      assert Clients.list_clients() == []
    end
  end

  describe "saving" do
    test "creates the client and returns to the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      assert {:error, {:live_redirect, %{to: "/clients"}}} =
               view
               |> form("#client-form", %{"client" => valid_params()})
               |> render_submit()

      assert [client] = Clients.list_clients()
      assert client.name == "Acme Traders Private Limited"
      assert client.gstin == "27AABCA1234A1Z5"
      assert client.status == "Active"
      # Copied because "same as billing" is on by default.
      assert client.shipping_city == "Mumbai"
    end

    test "an unregistered client saves with no GSTIN", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      params =
        valid_params(%{"client_type" => "Unregistered", "gstin" => "", "name" => "Walk-in"})

      assert {:error, {:live_redirect, %{to: "/clients"}}} =
               view |> form("#client-form", %{"client" => params}) |> render_submit()

      assert [client] = Clients.list_clients()
      assert client.gstin == nil
    end

    test "trade terms from the optional section are stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      params =
        valid_params(%{
          "credit_limit" => "50000",
          "payment_terms_days" => "45",
          "notes" => "Pays on time."
        })

      view |> form("#client-form", %{"client" => params}) |> render_submit()

      assert [client] = Clients.list_clients()
      assert client.credit_limit == 50_000
      assert client.payment_terms_days == 45
      assert client.notes == "Pays on time."
    end

    test "a separate shipping address is kept", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/clients/new")

      # The shipping inputs do not exist until the box is unticked, so untick it
      # first — which is what a user does too.
      view
      |> form("#client-form", %{"client" => %{"shipping_same_as_billing" => "false"}})
      |> render_change()

      params =
        valid_params(%{
          "shipping_same_as_billing" => "false",
          "shipping_line1" => "Warehouse 4",
          "shipping_city" => "Pune",
          "shipping_state" => "Maharashtra (27)",
          "shipping_pin" => "411001"
        })

      view |> form("#client-form", %{"client" => params}) |> render_submit()

      assert [client] = Clients.list_clients()
      assert client.shipping_city == "Pune"
      assert client.billing_city == "Mumbai"
    end
  end
end
