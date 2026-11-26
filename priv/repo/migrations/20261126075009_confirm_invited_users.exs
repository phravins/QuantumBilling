defmodule QuantumBilling.Repo.Migrations.ConfirmInvitedUsers do
  use Ecto.Migration

  @moduledoc """
  Confirms the accounts that were created from an invitation but never confirmed.

  ## Why

  An invited account used to start unconfirmed and was sent a second email to
  confirm the same address, so it could not sign in with its password until
  that mail arrived. Without a working relay it never did. The invitation link
  had already been emailed to that address, so using it proved the mailbox;
  invited accounts now start confirmed, and this catches up the ones made before.

  ## Which accounts

  Only unconfirmed accounts whose address has an accepted invitation. An
  invitation is marked accepted only when someone registers from a link sent to
  that address (the same sign-up also claims the address's other invitations),
  and the registration form already held the account to the invited address.
  The confirmation time is when the invitation was accepted.

  Rolling back leaves the accounts confirmed: their addresses are proved either way.
  """

  @backfill """
  UPDATE public.users AS u
  SET confirmed_at = i.accepted_at
  FROM (
    SELECT lower(email) AS email, min(accepted_at) AS accepted_at
    FROM public.invitations
    WHERE accepted_at IS NOT NULL
    GROUP BY lower(email)
  ) AS i
  WHERE u.confirmed_at IS NULL
    AND lower(u.email::text) = i.email
  """

  @doc false
  # Public so the test can run the same statement.
  def backfill_sql, do: @backfill

  def up do
    execute @backfill
  end

  def down, do: :ok
end
