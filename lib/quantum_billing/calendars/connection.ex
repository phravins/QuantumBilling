defmodule QuantumBilling.Calendars.Connection do
  @moduledoc """
  A calendar this business sends its deadlines to. At most one per provider.

    * `google`: `secret` holds the refresh token.
    * `caldav`: `secret` holds the password, `url` the calendar collection.
    * `feed`: no secret, only the hash of the token in the subscription URL.

  `secret` and `feed_token_hash` are set in code and redacted from `inspect`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Encrypted
  alias QuantumBilling.Webhooks.UrlGuard

  @providers ~w(google caldav feed)

  schema "calendar_connections" do
    field :provider, :string
    field :secret, Encrypted.Secret, redact: true
    field :url, :string
    field :username, :string
    field :calendar_id, :string, default: "primary"
    field :feed_token_hash, :binary, redact: true
    field :last_synced_at, :utc_datetime
    field :last_error, :string
    field :password, :string, virtual: true, redact: true

    belongs_to :connected_by, QuantumBilling.Accounts.User

    has_many :event_links, QuantumBilling.Calendars.EventLink

    timestamps(type: :utc_datetime)
  end

  def providers, do: @providers

  def caldav_changeset(%__MODULE__{} = connection, attrs) do
    connection
    |> cast(attrs, [:url, :username, :password])
    |> update_change(:url, &trim/1)
    |> update_change(:username, &trim/1)
    |> validate_required([:url, :username, :password])
    |> validate_length(:url, max: 2000)
    |> validate_length(:username, max: 200)
    |> validate_length(:password, max: 1000)
    |> validate_change(:url, &validate_url/2)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

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
