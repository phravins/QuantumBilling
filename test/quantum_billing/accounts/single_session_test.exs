defmodule QuantumBilling.Accounts.SingleSessionTest do
  @moduledoc """
  "One device at a time" in Accounts: which sessions count as another device
  in use, ending them, and the sign-in requests the signed-in device answers.
  """
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.{SignInRequest, UserToken}

  setup do
    %{user: user_fixture()}
  end

  defp session(user, device_id),
    do: Accounts.generate_user_session_token(user, %{device_id: device_id})

  defp last_seen(token, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(:second), -seconds_ago, :second)
    Repo.update_all(from(t in UserToken, where: t.token == ^token), set: [last_seen_at: at])
  end

  defp request(user, device_id \\ "device-b") do
    {:ok, token} = Accounts.create_sign_in_request(user, %{device_id: device_id})
    {token, Accounts.get_sign_in_request(token)}
  end

  describe "active_session_elsewhere?/3" do
    test "counts another device used recently", %{user: user} do
      session(user, "device-a")

      assert Accounts.active_session_elsewhere?(user, "device-b", 60)
    end

    test "ignores this device's own sessions", %{user: user} do
      session(user, "device-a")

      refute Accounts.active_session_elsewhere?(user, "device-a", 60)
    end

    test "ignores a device idle longer than the timeout", %{user: user} do
      user |> session("device-a") |> last_seen(61 * 60)

      refute Accounts.active_session_elsewhere?(user, "device-b", 60)
    end

    test "ignores a session already replaced", %{user: user} do
      session(user, "device-a")
      Accounts.replace_sessions(user)

      refute Accounts.active_session_elsewhere?(user, "device-b", 60)
    end
  end

  describe "replace_sessions/2" do
    test "ends other devices' sessions and keeps this one's", %{user: user} do
      mine = session(user, "device-a")
      theirs = session(user, "device-b")

      assert [%{token: ^theirs}] = Accounts.replace_sessions(user, "device-a")

      assert Accounts.get_user_by_session_token(mine)
      refute Accounts.get_user_by_session_token(theirs)
      assert Accounts.session_replaced?(theirs)
      refute Accounts.session_replaced?(mine)
    end

    test "with no device kept, ends them all", %{user: user} do
      session(user, "device-a")
      session(user, "device-b")

      assert length(Accounts.replace_sessions(user)) == 2
    end
  end

  test "touch_session/1 marks a session in use, at most once a minute", %{user: user} do
    token = session(user, "device-a")
    last_seen(token, 600)

    Accounts.touch_session(token)

    assert %UserToken{last_seen_at: at} = Repo.get_by(UserToken, token: token)
    assert DateTime.diff(DateTime.utc_now(), at) < 5
  end

  describe "sign-in requests" do
    test "a new request cancels the one still pending", %{user: user} do
      {_old_token, old} = request(user)
      {_new_token, new} = request(user)

      assert Repo.get(SignInRequest, old.id).status == "cancelled"
      assert Accounts.pending_sign_in_request(user).id == new.id
    end

    test "only its hash is stored", %{user: user} do
      {token, request} = request(user)

      refute request.token == token
    end

    test "the first answer wins", %{user: user} do
      {_token, request} = request(user)

      assert {:ok, %SignInRequest{status: "approved"}} =
               Accounts.answer_sign_in_request(user, request.id, :approve)

      assert {:error, :closed} = Accounts.answer_sign_in_request(user, request.id, :deny)
    end

    test "an expired request cannot be allowed", %{user: user} do
      {_token, request} = request(user)

      Repo.update_all(from(r in SignInRequest, where: r.id == ^request.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      assert {:error, :closed} = Accounts.answer_sign_in_request(user, request.id, :approve)
    end

    test "another user cannot answer it", %{user: user} do
      {_token, request} = request(user)

      assert {:error, :closed} =
               Accounts.answer_sign_in_request(user_fixture(), request.id, :approve)
    end

    test "an allowed request signs in once", %{user: user} do
      {token, request} = request(user)
      {:ok, _} = Accounts.answer_sign_in_request(user, request.id, :approve)

      assert {:ok, %{id: id}} = Accounts.consume_approved_sign_in_request(token)
      assert id == user.id
      assert {:error, "missing"} = Accounts.consume_approved_sign_in_request(token)
    end

    test "a pending, refused or cancelled request signs nobody in", %{user: user} do
      {pending, _request} = request(user)
      assert {:error, "pending"} = Accounts.consume_approved_sign_in_request(pending)

      {denied, request} = request(user)
      {:ok, _} = Accounts.answer_sign_in_request(user, request.id, :deny)
      assert {:error, "denied"} = Accounts.consume_approved_sign_in_request(denied)

      {cancelled, _request} = request(user)
      Accounts.cancel_sign_in_request(cancelled)
      assert {:error, "cancelled"} = Accounts.consume_approved_sign_in_request(cancelled)
    end

    test "an allowed request not used in time expires", %{user: user} do
      {token, request} = request(user)
      {:ok, _} = Accounts.answer_sign_in_request(user, request.id, :approve)

      Repo.update_all(from(r in SignInRequest, where: r.id == ^request.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      assert {:error, "expired"} = Accounts.consume_approved_sign_in_request(token)
    end

    test "answers reach the waiting browser and the user's pages", %{user: user} do
      {token, request} = request(user)
      QuantumBilling.Events.subscribe(Accounts.sign_in_request_topic(token))
      Accounts.subscribe_user(user)

      {:ok, _} = Accounts.answer_sign_in_request(user, request.id, :deny)

      assert_receive {:sign_in_request_answered, "denied"}
      request_id = request.id
      assert_receive {:sign_in_request_closed, ^request_id}
    end
  end
end
