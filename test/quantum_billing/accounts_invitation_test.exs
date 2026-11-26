defmodule QuantumBilling.AccountsInvitationTest do
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.{Accounts, Businesses}

  defp non_member_user_fixture(business, attrs) do
    user = user_fixture(attrs)
    _ = Accounts.remove_member(business, user)
    user
  end

  test "inviting an existing user creates a pending invitation rather than immediate membership" do
    owner = owner_fixture()
    business = Businesses.default!()
    existing_user = non_member_user_fixture(business, %{email: "existing@example.com"})

    assert {:ok, {:invited, invitation}} =
             Accounts.invite(business, "existing@example.com", "owner", owner, &"/invitations/#{&1}")

    assert invitation.email == "existing@example.com"
    assert invitation.role == "owner"
    assert is_nil(Businesses.get_membership(existing_user, business.id))
    assert [pending] = Accounts.list_pending_invitations(existing_user)
    assert pending.id == invitation.id
  end

  test "accepting an invitation creates membership with the invited role and removes pending state" do
    owner = owner_fixture()
    business = Businesses.default!()
    existing_user = non_member_user_fixture(business, %{email: "member@example.com"})

    {:ok, {:invited, invitation}} =
      Accounts.invite(business, "member@example.com", "staff", owner, &"/invitations/#{&1}")

    assert {:ok, membership} = Accounts.accept_invitation(existing_user, invitation)
    assert membership.role == "staff"
    assert membership.user_id == existing_user.id
    assert membership.business_id == business.id
    assert Businesses.get_membership(existing_user, business.id)
    assert Accounts.list_pending_invitations(existing_user) == []
  end

  test "declining an invitation deletes it without adding membership" do
    owner = owner_fixture()
    business = Businesses.default!()
    existing_user = non_member_user_fixture(business, %{email: "decline@example.com"})

    {:ok, {:invited, invitation}} =
      Accounts.invite(business, "decline@example.com", "staff", owner, &"/invitations/#{&1}")

    assert {:ok, _} = Accounts.decline_invitation(existing_user, invitation)
    assert is_nil(Businesses.get_membership(existing_user, business.id))
    assert Accounts.list_pending_invitations(existing_user) == []
  end

  test "a signed-in user cannot accept an invitation addressed to another email" do
    owner = owner_fixture()
    business = Businesses.default!()
    _target = non_member_user_fixture(business, %{email: "target@example.com"})
    other_user = non_member_user_fixture(business, %{email: "other@example.com"})

    {:ok, {:invited, invitation}} =
      Accounts.invite(business, "target@example.com", "owner", owner, &"/invitations/#{&1}")

    assert {:error, :email_mismatch} = Accounts.accept_invitation(other_user, invitation)
    assert is_nil(Businesses.get_membership(other_user, business.id))
  end
end