defmodule QuantumBilling.Repo.Migrations.CreateNotifications do
  @moduledoc """
  The in-app notification feed behind the bell in the top bar.

  Until now that bell was a button with a permanently lit red dot and nothing
  behind it: there was no table, no feed, and nothing ever marked it read. The
  three `notify_*` switches in Settings ≥ Notifications gated one email apiece
  and nothing on screen.

  Rows are the organisation's, not one user's — the same way its clients and
  its invoices are, and for the same reason: two signed-in people are looking
  at the same books. `read_at` is therefore shared as well. Per-user read state
  needs a join table, and that belongs with the per-user work rather than here.

  `dedupe_key` is what makes a producer safe to call twice. A filing reminder
  runs every morning against the same deadline, a payment webhook is redelivered,
  a recurring sweep re-raises the same invoice — each of them writes the same
  key, and the unique index turns the repeat into a no-op instead of a second
  line in the feed. It is nullable because a genuinely one-off notice has
  nothing sensible to put there, hence the partial index.
  """
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :string
      add :path, :string
      add :severity, :string, null: false, default: "info"
      add :dedupe_key, :string
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # The feed's only ordering: newest first, tie-broken by id so a page
    # boundary cannot show the same row twice.
    create index(:notifications, [:inserted_at, :id])

    # What the bell's badge counts, every time any page in the app mounts.
    create index(:notifications, [:read_at], where: "read_at IS NULL")

    create unique_index(:notifications, [:dedupe_key], where: "dedupe_key IS NOT NULL")
  end
end
