defmodule QuantumBilling.Repo.Migrations.EncryptWebhookEventPayloads do
  @moduledoc """
  Moves `webhook_events.payload` from plaintext JSON to an encrypted binary
  (`QuantumBilling.Encrypted.Map`), trimming each stored Razorpay event to what
  reconciliation needs on the way. Runs in the migration's transaction, so the
  table is converted completely or not at all.
  """
  use Ecto.Migration

  import Ecto.Query

  alias QuantumBilling.Encrypted
  alias QuantumBilling.Payments

  def up do
    alter table(:webhook_events) do
      add :payload_ciphertext, :binary
    end

    flush()

    for {id, provider, payload} <- rows(:payload) do
      record = if provider == "razorpay", do: Payments.webhook_record(payload || %{}), else: %{}

      put_row(id, payload_ciphertext: Encrypted.Map.encrypt(record))
    end

    alter table(:webhook_events) do
      remove :payload
    end

    rename table(:webhook_events), :payload_ciphertext, to: :payload

    flush()

    execute "ALTER TABLE webhook_events ALTER COLUMN payload SET NOT NULL"
  end

  def down do
    alter table(:webhook_events) do
      add :payload_json, :map, null: false, default: "{}"
    end

    flush()

    for {id, _provider, ciphertext} <- rows(:payload) do
      payload =
        case Encrypted.Map.load(ciphertext) do
          {:ok, map} when is_map(map) -> map
          _unreadable -> %{}
        end

      put_row(id, payload_json: payload)
    end

    alter table(:webhook_events) do
      remove :payload
    end

    rename table(:webhook_events), :payload_json, to: :payload
  end

  defp rows(column) do
    repo().all(from(e in "webhook_events", select: {e.id, e.provider, field(e, ^column)}))
  end

  defp put_row(id, changes) do
    repo().update_all(from(e in "webhook_events", where: e.id == ^id), set: changes)
  end
end
