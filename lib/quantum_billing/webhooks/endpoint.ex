defmodule QuantumBilling.Webhooks.Endpoint do
  @moduledoc """
  One URL this business sends events to.

  The secret is generated here, never typed: it is shown to the owner once,
  stored encrypted, and used to sign every delivery. Rotating it keeps the old
  one valid for a day (`previous_secret`), so the receiver can be updated
  without dropping events in between.

  Two body formats:

    * `thin` — every endpoint created from now on: `{id, type, created_at,
      data: {object, id}}`, signed over the timestamp and the body. The receiver
      fetches the record itself through the API.
    * `legacy` — only the endpoint carried over from the old single webhook
      setting, so its receiver keeps getting what it was built for.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Encrypted
  alias QuantumBilling.Webhooks.UrlGuard

  @formats ~w(thin legacy)

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

  def formats, do: @formats

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
