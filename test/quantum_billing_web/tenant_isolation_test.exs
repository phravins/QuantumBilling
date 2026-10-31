defmodule QuantumBillingWeb.TenantIsolationTest do
  @moduledoc """
  A member of one business never reaches another's records — not by forging a
  `business_id` into their session, and not by guessing ids, which repeat
  across businesses because each has its own schema.

  Not async: creating a business runs DDL.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.{Businesses, Repo}
  alias QuantumBilling.Invoices.Invoice

  setup do
    {:ok, other} =
      Businesses.create(QuantumBilling.AccountsFixtures.owner_fixture(), %{"name" => "Rival Co"})

    Repo.put_business(Businesses.default!())

    insert = fn attrs ->
      Repo.insert!(
        struct(
          Invoice,
          Map.merge(
            %{
              invoice_number: "INV-#{System.unique_integer([:positive])}",
              invoice_date: ~D[2026-03-01],
              place_of_supply: "Maharashtra (27)",
              grand_total: 100
            },
            attrs
          )
        )
      )
    end

    mine = insert.(%{client_name: "Our Own Customer"})

    # The same id in the other business's schema: ids repeat across businesses.
    theirs =
      Repo.with_business(other, fn ->
        insert.(%{id: mine.id, client_name: "Rival Secret Customer"})
      end)

    assert theirs.id == mine.id

    %{other: other, mine: mine}
  end

  defp member_conn(opts) do
    user = QuantumBilling.AccountsFixtures.user_fixture()
    log_in_user(build_conn(), user, opts)
  end

  test "a forged business_id in the session is ignored", %{other: other, mine: mine} do
    conn = member_conn(business_id: other.id)

    for path <- [
          "/invoices/#{mine.id}/pdf",
          "/invoices/#{mine.id}/pdf/download",
          "/reports/export"
        ] do
      body = conn |> get(path) |> Map.get(:resp_body)
      refute body =~ "Rival Secret Customer", "#{path} served the other business's data"
    end

    {:ok, _view, html} = live(conn, ~p"/invoices/#{mine.id}")
    assert html =~ "Our Own Customer"
    refute html =~ "Rival Secret Customer"
  end

  test "the invoice list shows only the member's business", %{other: other} do
    conn = member_conn(business_id: other.id)

    {:ok, _view, html} = live(conn, ~p"/invoices")

    assert html =~ "Our Own Customer"
    refute html =~ "Rival Secret Customer"
  end

  test "someone in no business at all is sent to the picker, not into one" do
    user = QuantumBilling.AccountsFixtures.user_fixture()
    {:ok, _} = QuantumBilling.Accounts.remove_member(Businesses.default!(), user)
    conn = log_in_user(build_conn(), user)

    assert redirected_to(get(conn, ~p"/invoices/1/pdf")) == ~p"/businesses"
    assert {:error, {:redirect, %{to: "/businesses"}}} = live(conn, ~p"/invoices")
  end
end
