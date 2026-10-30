defmodule QuantumBilling.Repo.Migrations.MoveBusinessTablesIntoTheirOwnSchema do
  use Ecto.Migration

  @moduledoc """
  Makes room for several businesses on one installation.

  Each business keeps its records in a Postgres schema of its own — `biz_1`,
  `biz_2`, … — with its own copy of the business tables, so one firm's
  invoices, clients and numbering never mix with another's. Accounts stay in
  `public` and are shared: one person signs in once and works in the firms they
  are a member of.

  ## What happens to the data already here

  It becomes business 1, untouched. `ALTER TABLE … SET SCHEMA` only changes
  where Postgres files each table; no row is copied, and the indexes,
  constraints and id sequences move with their table. Every account becomes a
  member of business 1 with the role it already had — roles belong to the
  membership from now on, so `users.role` goes — and the sign-in rules move
  to `installation_settings`, because they protect the sign-in page, before
  anyone has chosen a business.

  `biz_1` is then marked as already holding the tenant baseline, so the tenant
  migrator does not try to create the tables it has just been given. Newer
  businesses get the same tables from that baseline.

  A fresh database goes through the same steps with empty tables, so every
  installation has business 1.
  """

  # The tables that belong to a business. Everything else stays in public.
  @tables ~w(organization_settings clients invoices invoice_items credit_notes e_way_bills
             e_way_bill_part_b_updates recurring_profiles invoice_templates notifications
             email_deliveries audit_logs webhook_events)

  # priv/repo/tenant_migrations/20261015115500_tenant_baseline.exs
  @baseline_version 20_261_015_115_500

  def up do
    create table(:businesses) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :schema, :string, null: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:businesses, [:slug])
    create unique_index(:businesses, [:schema])

    # The schema name is put into SQL as an identifier, so only this shape.
    create constraint(:businesses, :businesses_schema_valid, check: "schema ~ '^biz_[0-9]+$'")

    create table(:memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :business_id, references(:businesses, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "staff"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:user_id, :business_id])
    create index(:memberships, [:business_id])

    create constraint(:memberships, :memberships_role_valid, check: "role IN ('owner', 'staff')")

    create table(:installation_settings) do
      add :allowed_ips, :string
      add :session_timeout_minutes, :integer, null: false, default: 60
      add :enforce_2fa, :boolean, null: false, default: false
      add :singleton, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:installation_settings, [:singleton])

    create constraint(:installation_settings, :installation_settings_singleton,
             check: "singleton"
           )

    create constraint(:installation_settings, :installation_settings_timeout_positive,
             check: "session_timeout_minutes > 0"
           )

    # An invitation is to one business.
    alter table(:invitations) do
      add :business_id, references(:businesses, on_delete: :delete_all)
    end

    create index(:invitations, [:business_id])

    execute """
    INSERT INTO businesses (id, name, slug, schema, inserted_at, updated_at)
    VALUES (
      1,
      COALESCE(
        (SELECT NULLIF(btrim(company_name), '') FROM organization_settings ORDER BY id LIMIT 1),
        'My business'
      ),
      'main',
      'biz_1',
      now(),
      now()
    )
    """

    execute "SELECT setval(pg_get_serial_sequence('businesses', 'id'), 1)"

    execute """
    INSERT INTO memberships (user_id, business_id, role, inserted_at, updated_at)
    SELECT id, 1, role, now(), now() FROM users
    """

    execute "UPDATE invitations SET business_id = 1"
    execute "ALTER TABLE invitations ALTER COLUMN business_id SET NOT NULL"

    # One live invitation per address in each business, rather than per
    # installation: two firms may invite the same accountant.
    drop index(:invitations, [:email], name: :invitations_pending_email_unique)

    create unique_index(:invitations, [:business_id, :email],
             where: "accepted_at IS NULL",
             name: :invitations_pending_email_unique
           )

    # The role is the membership's now; a stale copy on the account would only
    # ever be read by mistake.
    drop constraint(:users, :users_role_valid)

    alter table(:users) do
      remove :role
    end

    execute """
    INSERT INTO installation_settings
      (allowed_ips, session_timeout_minutes, enforce_2fa, singleton, inserted_at, updated_at)
    SELECT allowed_ips, COALESCE(session_timeout_minutes, 60), COALESCE(enforce_2fa, false),
           true, now(), now()
    FROM organization_settings ORDER BY id LIMIT 1
    """

    execute "CREATE SCHEMA biz_1"

    for table <- @tables do
      execute "ALTER TABLE public.#{table} SET SCHEMA biz_1"
    end

    # The same table Ecto.Migrator creates for a prefix.
    execute """
    CREATE TABLE biz_1.schema_migrations (
      version bigint PRIMARY KEY,
      inserted_at timestamp(0) without time zone
    )
    """

    execute "INSERT INTO biz_1.schema_migrations VALUES (#{@baseline_version}, now())"
  end

  def down do
    # Only business 1 can go back into public; anything newer has nowhere to go.
    execute """
    DO $$
    BEGIN
      IF (SELECT count(*) FROM businesses) > 1 THEN
        RAISE EXCEPTION 'more than one business exists; remove the others before rolling back';
      END IF;
    END
    $$
    """

    for table <- @tables do
      execute "ALTER TABLE biz_1.#{table} SET SCHEMA public"
    end

    execute "DROP TABLE biz_1.schema_migrations"
    execute "DROP SCHEMA biz_1"

    alter table(:users) do
      add :role, :string, null: false, default: "staff"
    end

    execute """
    UPDATE users SET role = m.role
    FROM memberships m WHERE m.user_id = users.id AND m.business_id = 1
    """

    create constraint(:users, :users_role_valid, check: "role IN ('owner', 'staff')")

    drop index(:invitations, [:business_id, :email], name: :invitations_pending_email_unique)

    alter table(:invitations) do
      remove :business_id
    end

    create unique_index(:invitations, [:email],
             where: "accepted_at IS NULL",
             name: :invitations_pending_email_unique
           )

    drop table(:installation_settings)
    drop table(:memberships)
    drop table(:businesses)
  end
end
