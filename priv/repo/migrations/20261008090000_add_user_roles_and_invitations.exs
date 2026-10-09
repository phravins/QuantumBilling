defmodule QuantumBilling.Repo.Migrations.AddUserRolesAndInvitations do
  use Ecto.Migration

  @moduledoc """
  Gives accounts a role, and makes registration invite-only.

  ## Why

  This application is single-tenant by design: one `organization_settings` row,
  and no owner column on invoices, clients or anything else, because it bills
  for one business. That is a reasonable design — but registration was open to
  the public and accounts had no role at all, so anyone who could reach the
  sign-up page could create an account, confirm their own email, and then read
  every invoice, every client's GSTIN and PAN, download the whole database from
  Settings, and change the SMTP relay and payment credentials.

  Confirming an email proves you own that mailbox. It does not prove the
  business wants you in its books.

  ## The backfill matters

  An install that already has users must not lock itself out. The oldest
  account becomes the owner, which on every real install is the person who set
  the application up. A fresh database has no users and the backfill does
  nothing; the first account registered afterwards becomes the owner instead.
  """

  def up do
    alter table(:users) do
      add :role, :string, null: false, default: "staff"
    end

    # The oldest account is the one that set this installation up.
    execute """
    UPDATE users SET role = 'owner'
    WHERE id = (SELECT id FROM users ORDER BY inserted_at ASC, id ASC LIMIT 1)
    """

    create constraint(:users, :users_role_valid, check: "role IN ('owner', 'staff')")

    create table(:invitations) do
      add :email, :string, null: false
      # Hashed, never stored raw — the same reasoning as `user_tokens`: a
      # database read must not hand over working invitations.
      add :token, :binary, null: false
      add :role, :string, null: false, default: "staff"
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :accepted_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token])
    create index(:invitations, [:email])

    create constraint(:invitations, :invitations_role_valid, check: "role IN ('owner', 'staff')")

    # One live invitation per address. Re-inviting someone replaces theirs
    # rather than leaving two valid tokens for one mailbox.
    create unique_index(:invitations, [:email],
             where: "accepted_at IS NULL",
             name: :invitations_pending_email_unique
           )
  end

  def down do
    drop table(:invitations)

    drop constraint(:users, :users_role_valid)

    alter table(:users) do
      remove :role
    end
  end
end
