defmodule QuantumBillingWeb.SingleSessionTest do
  @moduledoc """
  "One device at a time": a sign-in on a second device waits, and only the
  device already signed in can let it in ("Sign out here") or refuse it
  ("Continue"). The waiting device can only give up.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.{SignInRequest, UserToken}
  alias QuantumBilling.InstallationSettings
  alias QuantumBilling.Repo

  @chrome_windows "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

  defp single_session!(on? \\ true) do
    {:ok, _} = InstallationSettings.update(InstallationSettings.get(), %{single_session: on?})
  end

  defp sign_in(conn, user, extra \\ %{}) do
    post(conn, ~p"/users/log-in", %{
      "user" => Map.merge(%{"email" => user.email, "password" => valid_user_password()}, extra)
    })
  end

  # A browser waiting at /users/session-conflict, and its request.
  defp held(user) do
    conn = sign_in(build_conn(), user)
    assert redirected_to(conn) == ~p"/users/session-conflict"
    {conn, Accounts.pending_sign_in_request(user)}
  end

  setup do
    %{user: user_fixture() |> set_password()}
  end

  describe "with the switch off" do
    test "a second device signs in as before", %{user: user} do
      a = sign_in(build_conn(), user)
      b = sign_in(build_conn(), user)

      assert get_session(a, :user_token)
      assert get_session(b, :user_token)
      refute Accounts.pending_sign_in_request(user)
    end
  end

  describe "signing in on a second device" do
    setup do
      single_session!()
      :ok
    end

    test "with no other device in use, signs in", %{user: user} do
      conn = sign_in(build_conn(), user)

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "while another device is in use, waits signed out", %{user: user} do
      a = sign_in(build_conn(), user)
      {b, request} = held(user)

      refute get_session(b, :user_token)
      assert %SignInRequest{status: "pending"} = request
      # The device already signed in is untouched.
      assert Accounts.get_user_by_session_token(get_session(a, :user_token))
    end

    test "a device left idle past the timeout is signed out instead", %{user: user} do
      a = sign_in(build_conn(), user)
      a_token = get_session(a, :user_token)

      Repo.update_all(from(t in UserToken, where: t.token == ^a_token),
        set: [last_seen_at: DateTime.add(DateTime.utc_now(:second), -2 * 3600, :second)]
      )

      b = sign_in(build_conn(), user)

      assert get_session(b, :user_token)
      assert Accounts.session_replaced?(a_token)

      conn = get(a, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "signed in on another device"
    end

    test "the same browser signing in again does not wait for itself", %{user: user} do
      a = sign_in(build_conn(), user)

      # Same browser (its device cookie), but the session cookie is gone.
      again = a |> recycle() |> init_test_session(%{})
      conn = sign_in(again, user)

      assert get_session(conn, :user_token)
      refute Accounts.pending_sign_in_request(user)
    end

    test "the second factor is checked before anyone is asked", %{user: user} do
      user = enrol_two_factor(user)
      _a = log_in_user(build_conn(), user)

      b = sign_in(build_conn(), user)
      assert redirected_to(b) == ~p"/users/two-factor"
      refute Accounts.pending_sign_in_request(user)

      b =
        post(b, ~p"/users/two-factor", %{
          "user" => %{"code" => NimbleTOTP.verification_code(user.totp_secret)}
        })

      assert redirected_to(b) == ~p"/users/session-conflict"
      refute get_session(b, :user_token)
      assert Accounts.pending_sign_in_request(user)
    end

    test "requests are limited, so the other device cannot be flooded", %{user: user} do
      _a = log_in_user(build_conn(), user)

      for _ <- 1..3, do: held(user)

      conn = sign_in(build_conn(), user)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many sign-in requests"
    end
  end

  describe "the waiting device" do
    setup %{user: user} do
      single_session!()
      a = sign_in(build_conn(), user)
      {b, request} = held(user)
      %{a: a, b: b, request: request}
    end

    test "sees it is waiting, with only a way out", %{b: b} do
      {:ok, lv, _html} = live(b, ~p"/users/session-conflict")

      assert has_element?(lv, "#session-conflict-waiting")
      assert has_element?(lv, "#session-conflict-sign-out")
      refute has_element?(lv, "#session-conflict-finish[phx-trigger-action]")
    end

    test "is told when the other device stays signed in", %{b: b, user: user, request: request} do
      {:ok, lv, _html} = live(b, ~p"/users/session-conflict")

      {:ok, _} = Accounts.answer_sign_in_request(user, request.id, :deny)

      assert has_element?(lv, "#session-conflict-denied")
      refute has_element?(lv, "#session-conflict-waiting")
    end

    test "signs in once the other device allows it", %{a: a, b: b, user: user, request: request} do
      {:ok, lv, _html} = live(b, ~p"/users/session-conflict")

      {:ok, _} = Accounts.answer_sign_in_request(user, request.id, :approve)

      assert has_element?(lv, "#session-conflict-finish[phx-trigger-action]")

      conn = follow_trigger_action(form(lv, "#session-conflict-finish"), b)
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Whatever the other device still held is over.
      refute Accounts.get_user_by_session_token(get_session(a, :user_token))
    end

    test "cannot sign itself in before it is allowed", %{b: b} do
      conn = post(b, ~p"/users/session-conflict")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/session-conflict"
    end

    test "can give up, leaving the other device signed in", %{a: a, b: b, request: request} do
      conn = delete(b, ~p"/users/session-conflict")

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert Repo.get(SignInRequest, request.id).status == "cancelled"
      assert html_response(get(a, ~p"/users/settings"), 200)
    end

    test "without a held sign-in, the page sends you to log in" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/users/session-conflict")
    end
  end

  describe "the device already signed in" do
    setup %{user: user} do
      single_session!()
      conn = log_in_user(build_conn(), user)
      %{conn: conn, token: get_session(conn, :user_token)}
    end

    defp ask(user) do
      {:ok, token} =
        Accounts.create_sign_in_request(user, %{
          device_id: "device-b",
          user_agent: @chrome_windows,
          ip_address: "203.0.113.9"
        })

      {token, Accounts.pending_sign_in_request(user)}
    end

    test "is asked on the page it has open", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      refute has_element?(lv, "#sign-in-request-prompt")

      ask(user)

      assert has_element?(lv, "#sign-in-request-prompt", "Chrome · Windows")
      assert has_element?(lv, "#sign-in-request-sign-out")
      assert has_element?(lv, "#sign-in-request-continue")
    end

    test "is asked on a page opened after the request", %{conn: conn, user: user} do
      ask(user)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      assert has_element?(lv, "#sign-in-request-prompt")
    end

    test "Continue refuses the other sign-in and stays", %{conn: conn, user: user, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      {_token, request} = ask(user)

      lv |> element("#sign-in-request-continue") |> render_click()

      refute has_element?(lv, "#sign-in-request-prompt")
      assert Repo.get(SignInRequest, request.id).status == "denied"
      assert Accounts.get_user_by_session_token(token)
    end

    test "Sign out here lets the other device in and signs this one out",
         %{conn: conn, user: user, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      {_token, request} = ask(user)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               lv |> element("#sign-in-request-sign-out") |> render_click()

      assert Repo.get(SignInRequest, request.id).status == "approved"
      assert Accounts.session_replaced?(token)

      # Back again, it is told why it was signed out.
      assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
               live(conn, ~p"/dashboard")

      assert flash["error"] =~ "signed in on another device"
    end

    test "the prompt goes when the waiting device gives up", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      {token, _request} = ask(user)
      assert has_element?(lv, "#sign-in-request-prompt")

      Accounts.cancel_sign_in_request(token)

      refute has_element?(lv, "#sign-in-request-prompt")
    end
  end
end
