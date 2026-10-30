defmodule QuantumBillingWeb.BusinessPickerLiveTest do
  @moduledoc """
  Choosing, switching, creating and looking after businesses from the browser,
  and the public links that name a business by its slug.
  """
  # Not async: creating a business runs DDL.
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Businesses
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  defp create_other(%{user: user}) do
    {:ok, other} = Businesses.create(user, %{"name" => "Firm Two"})
    %{other: other}
  end

  defp invoice_fixture(attrs) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-0001",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Acme Corp",
          grand_total: 118_000,
          status: "Draft",
          public_token: "tok-#{System.unique_integer([:positive])}"
        },
        attrs
      )
    )
  end

  describe "an owner of two businesses" do
    setup [:register_and_log_in_owner, :create_other]

    test "sees both and can switch into either", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/businesses")

      assert has_element?(view, "#business-1")
      assert has_element?(view, "#business-#{other.id}")
      assert has_element?(view, "#choose-business-#{other.id}")

      conn = post(conn, ~p"/businesses/#{other.id}/switch")
      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :business_id) == other.id
    end

    test "other open tabs follow a switch", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      post(conn, ~p"/businesses/#{other.id}/switch")

      assert_redirect(view, ~p"/")
    end

    test "a tab in another browser does not follow", %{other: other, user: user} do
      elsewhere = log_in_user(build_conn(), user)
      {:ok, view, _html} = live(elsewhere, ~p"/dashboard")

      post(log_in_user(build_conn(), user), ~p"/businesses/#{other.id}/switch")

      # The view is still there and answering.
      assert render(view)
      refute_redirected(view)
    end

    test "creates a third and is switched into it", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/businesses/new")

      form = form(view, "#business-form", business: %{name: "Firm Three"})
      render_submit(form)

      assert has_element?(view, "#switch-to-new-business")
      assert Enum.any?(Businesses.list_for_user(user), fn {b, _m} -> b.name == "Firm Three" end)

      conn = follow_trigger_action(form(view, "#switch-to-new-business"), conn)
      assert redirected_to(conn) == ~p"/"
    end

    test "a blank name is refused on the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/businesses/new")

      view |> form("#business-form", business: %{name: " "}) |> render_submit()

      refute has_element?(view, "#switch-to-new-business")
      assert has_element?(view, "#business-form")
    end

    test "renames a business", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/businesses")

      view |> element("#rename-#{other.id}") |> render_click()
      assert has_element?(view, "#rename-business-#{other.id}")

      {:ok, view, _html} =
        view
        |> form("#rename-business-#{other.id}", business: %{name: "Firm Deux"})
        |> render_submit()
        |> follow_redirect(conn)

      assert view |> element("#business-#{other.id}") |> render() =~ "Firm Deux"
      assert Businesses.get(other.id).slug == other.slug
    end

    test "archives a business and restores it", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/businesses")

      {:ok, view, _html} =
        view |> element("#archive-#{other.id}") |> render_click() |> follow_redirect(conn)

      refute has_element?(view, "#business-#{other.id}")
      assert has_element?(view, "#archived-business-#{other.id}")

      {:ok, view, _html} =
        view |> element("#restore-#{other.id}") |> render_click() |> follow_redirect(conn)

      assert has_element?(view, "#business-#{other.id}")
      refute has_element?(view, "#archived-businesses")
    end

    test "the first business offers no archive button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/businesses")

      assert has_element?(view, "#rename-1")
      refute has_element?(view, "#archive-1")
    end
  end

  describe "a member of staff" do
    setup :register_and_log_in_user

    setup do
      {:ok, other} = Businesses.create(owner_fixture(), %{"name" => "Firm Two"})
      %{other: other}
    end

    test "cannot switch into a business they are not part of", %{conn: conn, other: other} do
      conn = post(conn, ~p"/businesses/#{other.id}/switch")
      assert conn.status == 404
      refute get_session(conn, :business_id) == other.id
    end

    test "gets a 404 for an id that is not a number", %{conn: conn} do
      assert post(conn, ~p"/businesses/nonsense/switch").status == 404
    end

    test "cannot open the new-business page", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/businesses"}}} = live(conn, ~p"/businesses/new")
    end

    test "sees no owner tools, and their events do nothing", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/businesses")

      assert has_element?(view, "#business-1")
      refute has_element?(view, "#business-#{other.id}")
      refute has_element?(view, "#rename-1")
      refute has_element?(view, "#picker-new-business")

      render_click(view, "rename", %{"id" => "1"})
      refute has_element?(view, "#rename-business-1")

      render_click(view, "archive", %{"id" => to_string(other.id)})
      assert Businesses.get(other.id).archived_at == nil
    end

    test "is sent to the picker once they belong to two and have chosen neither", %{
      conn: conn,
      user: user,
      other: other
    } do
      {:ok, _} = Businesses.put_membership(user, other, "staff")
      conn = delete_session(conn, :business_id)

      assert redirected_to(get(conn, ~p"/dashboard")) == ~p"/businesses"
    end
  end

  describe "public links" do
    setup do
      owner = owner_fixture()
      {:ok, other} = Businesses.create(owner, %{"name" => "Firm Two"})
      %{owner: owner, other: other}
    end

    test "a slugged link opens the invoice in its own business", %{conn: conn, other: other} do
      invoice =
        Repo.with_business(other, fn ->
          invoice_fixture(%{invoice_number: "INV-TWO-1", public_token: "tok-firm-two"})
        end)

      {:ok, view, html} = live(conn, ~p"/p/#{other.slug}/#{invoice.public_token}")
      assert html =~ "INV-TWO-1"
      assert render(view) =~ "INV-TWO-1"

      # The old, unslugged link leads to the first business, which has no such invoice.
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/pay/#{invoice.public_token}")
    end

    test "an unknown slug opens nothing", %{conn: conn} do
      invoice = invoice_fixture(%{public_token: "tok-first"})

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/p/no-such-firm/#{invoice.public_token}")
    end

    test "an archived business's links stop working", %{conn: conn, owner: owner, other: other} do
      invoice = Repo.with_business(other, fn -> invoice_fixture(%{public_token: "tok-gone"}) end)
      {:ok, _} = Businesses.archive(owner, other)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, ~p"/p/#{other.slug}/#{invoice.public_token}")
    end
  end
end
