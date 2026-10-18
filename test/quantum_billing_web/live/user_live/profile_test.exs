defmodule QuantumBillingWeb.UserLive.ProfileTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Accounts
  alias QuantumBilling.Audit

  setup :register_and_log_in_user

  test "shows the banner, the person and their contact details", %{conn: conn, user: user} do
    {:ok, user} =
      Accounts.update_user_profile(user, %{
        full_name: "Priya Sharma",
        designation: "Accounts Manager",
        phone: "+91 98765 43210"
      })

    {:ok, view, _html} = live(conn, ~p"/users/profile")

    assert has_element?(view, "#profile-hero #profile-banner")
    assert has_element?(view, "#profile-name", "Priya Sharma")
    assert has_element?(view, "#profile-avatar", "PS")
    assert has_element?(view, "#profile-contact", "+91 98765 43210")
    assert has_element?(view, "#profile-contact", user.email)
    assert has_element?(view, "#profile-edit")
  end

  test "the banner is seeded by the user id until it is shuffled", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/users/profile")

    assert has_element?(view, ~s(#profile-banner[data-seed="#{user.id}"]))

    view |> element("#banner-shuffle") |> render_click()

    seed = Accounts.get_user!(user.id).banner_seed
    assert is_integer(seed)
    assert has_element?(view, ~s(#profile-banner[data-seed="#{seed}"]))
  end

  test "lists the user's own recent activity", %{conn: conn, user: user} do
    {:ok, log} = Audit.log_event(:generate_irn, "Invoice", 123, user_id: user.id)
    {:ok, _other} = Audit.log_event(:generate_irn, "Invoice", 456)

    {:ok, view, _html} = live(conn, ~p"/users/profile")

    assert has_element?(view, "#profile-activity #activity-#{log.id}")
    refute has_element?(view, "#profile-activity", "456")
  end

  test "redirects when signed out" do
    conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/profile")
  end
end
