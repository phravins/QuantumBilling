defmodule QuantumBilling.Accounts.Invitation do
  @moduledoc """
  An invitation to one business for an address with no account yet (existing
  accounts are added directly). Registration is invite-only.

  The token is stored hashed, and an invitation only works for the address it
  was sent to.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.Businesses.Membership

  @hash_algorithm :sha256
  @rand_size 32

  @validity_days 7

  @schema_prefix "public"
  schema "invitations" do
    field :email, :string
    field :token, :binary
    field :role, :string, default: "staff"
    field :accepted_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :invited_by, User
    belongs_to :business, Business

    timestamps(type: :utc_datetime)
  end

  @doc "How many days an invitation stays usable."
  def validity_days, do: @validity_days

  @doc "Builds an invitation: `{raw_token, changeset}`. Only the token's hash is stored."
  def build(email, role, invited_by, %Business{} = business) when is_binary(email) do
    token = :crypto.strong_rand_bytes(@rand_size)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@validity_days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    changeset =
      %__MODULE__{}
      |> cast(%{email: email, role: role}, [:email, :role])
      |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must be a valid email address"
      )
      |> validate_length(:email, max: 160)
      |> validate_inclusion(:role, Membership.roles())
      |> put_change(:token, :crypto.hash(@hash_algorithm, token))
      |> put_change(:expires_at, expires_at)
      |> put_assoc(:invited_by, invited_by)
      |> put_change(:business_id, business.id)

    {Base.url_encode64(token, padding: false), changeset}
  end

  @doc """
  Query for a usable invitation (matching, unaccepted, unexpired), or `:error` for a malformed token.
  """
  def by_token_query(raw_token) when is_binary(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} ->
        hashed = :crypto.hash(@hash_algorithm, decoded)
        now = DateTime.utc_now()

        {:ok,
         from(i in __MODULE__,
           where: i.token == ^hashed,
           where: is_nil(i.accepted_at),
           where: i.expires_at > ^now
         )}

      :error ->
        :error
    end
  end

  def by_token_query(_raw_token), do: :error

  @doc "Whether this invitation can still be used."
  def pending?(%__MODULE__{accepted_at: nil, expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def pending?(_invitation), do: false
end
