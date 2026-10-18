defmodule QuantumBilling.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `QuantumBilling.Accounts` context.
  """

  import Ecto.Query

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def unique_username, do: "user#{System.unique_integer([:positive])}"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def valid_registration_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_username(),
      email: unique_user_email(),
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    })
  end

  @doc """
  Creates an unconfirmed account the way the sign-up form does: username, email
  and password, awaiting the emailed confirmation link.
  """
  def registered_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_registration_attributes()
      |> Accounts.register_user_with_password()

    user
  end

  @doc """
  An account awaiting confirmation, on the staff of business 1.
  """
  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    {:ok, _membership} = Businesses.put_membership(user, Businesses.default!(), "staff")
    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
  end

  @doc """
  A confirmed account that owns business 1.

  Registration is invite-only and the owner-only areas — the credential
  settings panels, Team, the full data export — are gated on this role, so a
  test that exercises them needs it explicitly. `user_fixture/1` deliberately
  stays staff: that is the weaker of the two, and the one a route test should
  be written against by default.
  """
  def owner_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, _membership} = Accounts.set_role(Businesses.default!(), user, "owner")
    user
  end

  @doc "`user`'s role in business 1 (or `business`), or `nil` when not a member."
  def role(user, business \\ Businesses.default!()) do
    case Businesses.get_membership(user, business.id) do
      nil -> nil
      membership -> membership.role
    end
  end

  @doc """
  Invites `email` into business 1 (or `:business`) and returns the raw
  invitation token.

  Registration is invite-only, so anything that exercises the sign-up form
  past the very first account has to come through here. The token is captured
  from the URL builder because that is the only place it exists — the database
  keeps only its hash.
  """
  def invitation_token_fixture(email, opts \\ []) do
    owner = Keyword.get_lazy(opts, :invited_by, &owner_fixture/0)
    business = Keyword.get_lazy(opts, :business, &Businesses.default!/0)
    role = Keyword.get(opts, :role, "staff")
    test_pid = self()

    {:ok, {:invited, _invitation}} =
      Accounts.invite(business, email, role, owner, fn token ->
        send(test_pid, {:invitation_token, token})
        "http://localhost/users/register?token=#{token}"
      end)

    receive do
      {:invitation_token, token} -> token
    after
      0 -> raise "invite/5 never built an invitation URL"
    end
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    QuantumBilling.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    QuantumBilling.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    QuantumBilling.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
