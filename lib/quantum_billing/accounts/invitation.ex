defmodule QuantumBilling.Accounts.Invitation do
  @moduledoc """
  An invitation to create an account on this installation.

  Registration is invite-only, so this is the only route to a second account.
  The token is hashed before it is stored, for the same reason `UserToken`
  hashes its own: whoever can read this table must not come away holding
  working invitations.

  An invitation is bound to the address it was sent to. Accepting it with a
  different email would turn one invitation into an open door, which is the
  thing being closed.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias QuantumBilling.Accounts.User

  @hash_algorithm :sha256
  @rand_size 32

  @validity_days 7

  schema "invitations" do
    field :email, :string
    field :token, :binary
    field :role, :string, default: "staff"
    field :accepted_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :invited_by, User

    timestamps(type: :utc_datetime)
  end

  @doc "How many days an invitation stays usable."
  def validity_days, do: @validity_days

  @doc """
  Builds an invitation, returning `{raw_token, changeset}`.

  The raw token goes in the email and is never written down; only its hash is
  stored, so the invitation cannot be reconstructed from the database.
  """
  def build(email, role, invited_by) when is_binary(email) do
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
      |> validate_inclusion(:role, User.roles())
      |> put_change(:token, :crypto.hash(@hash_algorithm, token))
      |> put_change(:expires_at, expires_at)
      |> put_assoc(:invited_by, invited_by)

    {Base.url_encode64(token, padding: false), changeset}
  end

  @doc """
  The query matching a usable invitation for `raw_token`.

  Usable means: the hash matches, it has not been accepted, and it has not
  expired. Returns `:error` for anything that is not even a token, so a
  malformed value never reaches the database.
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

  @doc "Marks an invitation accepted."
  def accept_changeset(%__MODULE__{} = invitation) do
    change(invitation, accepted_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc "Whether this invitation can still be used."
  def pending?(%__MODULE__{accepted_at: nil, expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def pending?(_invitation), do: false
end
