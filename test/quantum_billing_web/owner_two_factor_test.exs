defmodule QuantumBillingWeb.OwnerTwoFactorTest do
  @moduledoc """
  An owner can hand out accounts, issue API keys and export everything, so an
  owner's account needs a second factor whatever the installation's general
  setting says. Staff need it only when the installation requires it.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.{Businesses, Repo}

  defp unenrolled_owner do
    user = user_fixture()
    {:ok, _} = QuantumBilling.Accounts.set_role(Businesses.default!(), user, "owner")
    user
  end

  test "an owner without 2FA is sent to set it up, from every page" do
    conn = log_in_user(build_conn(), unenrolled_owner())

    for path <- ["/dashboard", "/invoices", "/settings/backup/download"] do
      response = get(conn, path)

      assert redirected_to(response) == "/users/settings",
             "#{path} let an unenrolled owner through"

      assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "Two-factor"
    end
  end

  test "the pages needed to comply stay open" do
    conn = log_in_user(build_conn(), unenrolled_owner())

    assert html_response(get(conn, "/users/settings"), 200)
  end

  test "starting enrolment without confirming a code does not count" do
    owner = unenrolled_owner()

    owner
    |> Ecto.Changeset.change(totp_secret: NimbleTOTP.secret(), totp_confirmed_at: nil)
    |> Repo.update!()

    conn = log_in_user(build_conn(), owner)

    assert redirected_to(get(conn, "/dashboard")) == "/users/settings"
  end

  test "an enrolled owner goes about their business" do
    conn = log_in_user(build_conn(), owner_fixture())

    assert html_response(get(conn, "/dashboard"), 200)
  end

  test "staff are not required to enrol unless the installation says so" do
    conn = log_in_user(build_conn(), user_fixture())

    assert html_response(get(conn, "/dashboard"), 200)
  end
end
