defmodule QuantumBillingWeb.TwoFactorPolicyTest do
  @moduledoc """
  Two-factor is optional, for owners and staff alike, until an owner turns on
  "Enforce 2FA for everyone"; then everyone without it is sent to set it up.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.{Businesses, InstallationSettings, Repo}

  defp unenrolled_owner do
    user = user_fixture()
    {:ok, _} = QuantumBilling.Accounts.set_role(Businesses.default!(), user, "owner")
    user
  end

  defp enforce_two_factor! do
    {:ok, _} = InstallationSettings.update(InstallationSettings.get(), %{enforce_2fa: true})
  end

  describe "by default" do
    test "an owner without 2FA uses the app" do
      conn = log_in_user(build_conn(), unenrolled_owner())

      for path <- ["/dashboard", "/invoices"] do
        assert html_response(get(conn, path), 200), "#{path} turned an unenrolled owner away"
      end
    end

    test "staff without 2FA use the app" do
      conn = log_in_user(build_conn(), user_fixture())

      assert html_response(get(conn, "/dashboard"), 200)
    end
  end

  describe "with Enforce 2FA for everyone on" do
    setup do
      enforce_two_factor!()
      :ok
    end

    test "anyone without 2FA is sent to set it up, from every page" do
      for user <- [unenrolled_owner(), user_fixture()] do
        conn = log_in_user(build_conn(), user)

        for path <- ["/dashboard", "/invoices"] do
          response = get(conn, path)

          assert redirected_to(response) == "/users/settings",
                 "#{path} let an unenrolled user through"

          assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "Two-factor"
        end
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

    test "an enrolled user goes about their business" do
      conn = log_in_user(build_conn(), owner_fixture())

      assert html_response(get(conn, "/dashboard"), 200)
    end
  end
end
