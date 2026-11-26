# `mix test` migrates first, which loads the migration; otherwise load it here.
unless Code.ensure_loaded?(QuantumBilling.Repo.Migrations.ConfirmInvitedUsers) do
  Code.require_file(
    "../../priv/repo/migrations/20261126075009_confirm_invited_users.exs",
    __DIR__
  )
end

defmodule QuantumBilling.ConfirmInvitedUsersMigrationTest do
  @moduledoc """
  The backfill that confirms accounts created from an invitation before
  invited accounts started confirmed.
  """
  use QuantumBilling.DataCase, async: true

  import Ecto.Query
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.{Invitation, User}
  alias QuantumBilling.Repo.Migrations.ConfirmInvitedUsers

  test "confirms an invited account left unconfirmed, as of its invitation" do
    _first = registered_user_fixture()
    invited = invited_user_fixture("invited@example.com")
    set_confirmed_at(invited, nil)

    backfill!()

    accepted_at =
      Repo.one!(
        from i in Invitation, where: i.email == "invited@example.com", select: i.accepted_at
      )

    assert accepted_at
    assert Accounts.get_user!(invited.id).confirmed_at == accepted_at
  end

  test "leaves alone accounts with no accepted invitation" do
    first = registered_user_fixture()
    uninvited = unconfirmed_user_fixture()
    _token = invitation_token_fixture("pending@example.com")
    pending = unconfirmed_user_fixture(email: "pending@example.com")

    backfill!()

    refute Accounts.get_user!(first.id).confirmed_at
    refute Accounts.get_user!(uninvited.id).confirmed_at
    refute Accounts.get_user!(pending.id).confirmed_at
  end

  test "keeps the confirmation time an account already has" do
    _first = registered_user_fixture()
    invited = invited_user_fixture("invited@example.com")
    set_confirmed_at(invited, ~U[2026-01-01 00:00:00Z])

    backfill!()

    assert Accounts.get_user!(invited.id).confirmed_at == ~U[2026-01-01 00:00:00Z]
  end

  defp invited_user_fixture(email) do
    token = invitation_token_fixture(email)

    {:ok, user} =
      Accounts.register_user_with_password(valid_registration_attributes(email: email), token)

    user
  end

  defp set_confirmed_at(user, confirmed_at) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [confirmed_at: confirmed_at])
  end

  defp backfill!, do: Repo.query!(ConfirmInvitedUsers.backfill_sql())
end
