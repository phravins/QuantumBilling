defmodule QuantumBilling.ApiKeys.IdempotencyKey do
  @moduledoc """
  The record of one write made with an `Idempotency-Key`.

  Kept so that the same request, sent again, gets the same answer instead of
  being performed twice. `status` is nil while the first attempt is still
  running, which is how a concurrent retry knows to wait rather than run.
  """
  use Ecto.Schema

  alias QuantumBilling.ApiKeys.ApiKey

  @schema_prefix "public"
  schema "api_idempotency_keys" do
    field :key, :string
    field :request_hash, :binary
    field :status, :integer
    field :response_body, :string

    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime)
  end
end
