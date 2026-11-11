defmodule QuantumBilling.Webhooks.Endpoint do
  @moduledoc """
  One URL this business sends events to.

  The signing secret is generated, shown once and stored encrypted. Rotation
  keeps `previous_secret` valid for a day. Formats: `thin` (`{id, type,
  created_at, data: {object, id}}`; the receiver fetches the record) and
  `legacy` (only the endpoint migrated from the old single webhook).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Encrypted
  alias QuantumBilling.Webhooks.UrlGuard

  schema "webhook_endpoints" do
    field :url, :string
    field :description, :string
    field :events, {:array, :string}, default: []
    field :format, :string, default: "thin"
    field :secret, Encrypted.Secret, redact: true
    field :previous_secret, Encrypted.Secret, redact: true
    field :previous_secret_expires_at, :utc_datetime
    field :enabled, :boolean, default: true
    field :consecutive_failures, :integer, default: 0
    field :disabled_reason, :string
    field :disabled_at, :utc_datetime

    belongs_to :created_by, QuantumBilling.Accounts.User

    has_many :deliveries, QuantumBilling.Webhooks.Delivery

    timestamps(type: :utc_datetime)
  end

  @doc "What an owner may set: where, which events, and a note."
  def changeset(%__MODULE__{} = endpoint, attrs, event_types) do
    endpoint
    |> cast(attrs, [:url, :description, :events])
    |> update_change(:url, &String.trim/1)
    |> update_change(:events, &Enum.uniq/1)
    |> validate_required([:url])
    |> validate_length(:url, max: 2000)
    |> validate_length(:description, max: 120)
    |> validate_some_event()
    |> validate_subset(:events, event_types)
    |> validate_change(:url, &validate_url/2)
  end

  # Not validate_length(min: 1): an empty list equals the default, so casting
  # `[]` records no change and a length validation would never run.
  defp validate_some_event(changeset) do
    case get_field(changeset, :events) do
      [_ | _] -> changeset
      _none -> add_error(changeset, :events, "choose at least one event")
    end
  end

  # https only for new URLs: the body names records, and the signature proves
  # who sent it, not that nobody read it on the way.
  defp validate_url(field, url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", userinfo: nil}} ->
        case UrlGuard.check(url) do
          :ok -> []
          {:error, reason} -> [{field, reason}]
        end

      {:ok, %URI{userinfo: userinfo}} when not is_nil(userinfo) ->
        [{field, "must not contain a username or password"}]

      _other ->
        [{field, "must be a full https:// URL"}]
    end
  end
end
