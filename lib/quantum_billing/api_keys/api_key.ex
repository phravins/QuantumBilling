defmodule QuantumBilling.ApiKeys.ApiKey do
  @moduledoc """
  A revocable API credential, issued by an owner with specific scopes.

  Only the SHA-256 is stored; the raw key is shown once. A key reaches one
  business only, but lives in `public` so a request can find it first.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.Business

  @hash_algorithm :sha256
  @rand_size 32

  # Recognisable in a log, a config file or a secret scanner's rules. A key
  # that announces what it is gets reported when it leaks.
  @key_prefix "qb_live_"

  # Characters kept in clear after the marker, to tell keys apart in a list.
  @display_length byte_size(@key_prefix) + 8

  # Least privilege: no scope implies another. Payment links, payments and
  # e-invoice registration are separate scopes from read and write.
  @scopes ~w(invoices:read invoices:write invoices:payment_links invoices:payments
             invoices:e_invoice clients:read clients:write e_way_bills:read
             credit_notes:read credit_notes:write)

  @schema_prefix "public"
  schema "api_keys" do
    field :name, :string
    field :prefix, :string
    field :hashed_key, :binary, redact: true
    field :scopes, {:array, :string}, default: []
    field :last_used_at, :utc_datetime
    field :last_used_ip, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :business, Business
    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  @doc "Every scope a key can be granted."
  def scopes, do: @scopes

  @doc "Builds a new key: `{raw_key, changeset}`. Only the hash and a display prefix are stored."
  def build(attrs, %User{} = created_by, %Business{} = business) do
    raw = @key_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)

    changeset =
      %__MODULE__{}
      |> cast(attrs, [:name, :scopes, :expires_at])
      |> update_change(:name, &String.trim/1)
      |> validate_required([:name])
      |> validate_length(:name, max: 80)
      |> update_change(:scopes, &Enum.uniq/1)
      |> validate_some_scope()
      |> validate_subset(:scopes, @scopes)
      |> validate_future(:expires_at)
      |> put_change(:prefix, String.slice(raw, 0, @display_length))
      |> put_change(:hashed_key, hash(raw))
      |> put_change(:business_id, business.id)
      |> put_assoc(:created_by, created_by)
      |> unique_constraint(:prefix)
      |> unique_constraint(:hashed_key)

    {raw, changeset}
  end

  @doc "The stored form of a raw key."
  def hash(raw) when is_binary(raw), do: :crypto.hash(@hash_algorithm, raw)

  @doc "Whether `raw` is even shaped like a key, before any database work."
  def well_formed?(raw) when is_binary(raw) do
    String.starts_with?(raw, @key_prefix) and byte_size(raw) in 40..80
  end

  def well_formed?(_raw), do: false

  @doc "Whether the key can be used right now."
  def usable?(%__MODULE__{revoked_at: nil, expires_at: nil}), do: true

  def usable?(%__MODULE__{revoked_at: nil, expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  def usable?(_key), do: false

  @doc "Whether the key holds `scope`."
  def has_scope?(%__MODULE__{scopes: scopes}, scope), do: scope in scopes

  @doc "Marks a key revoked."
  def revoke_changeset(%__MODULE__{} = key),
    do: change(key, revoked_at: DateTime.utc_now(:second))

  # Not `validate_length(min: 1)`: casting `[]` records no change, so it would never run.
  defp validate_some_scope(changeset) do
    case get_field(changeset, :scopes) do
      [_ | _] -> changeset
      _none -> add_error(changeset, :scopes, "choose at least one permission")
    end
  end

  defp validate_future(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if DateTime.compare(value, DateTime.utc_now()) == :gt,
        do: [],
        else: [{field, "must be in the future"}]
    end)
  end
end
