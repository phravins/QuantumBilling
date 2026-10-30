defmodule QuantumBilling.ApiKeys.ApiKey do
  @moduledoc """
  A credential an external system uses to call the API.

  Issued by an owner, limited to the scopes it was given, and revocable. The
  raw key exists in exactly two places: the response to the request that
  created it, shown once, and the system the owner pastes it into. This table
  holds only its SHA-256, so reading the database yields no key that works.

  A key belongs to one business and reaches that business's books only. It is
  kept in `public` because a request has to find its key before it can know
  which business it is for.
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

  # How much of the key is kept in clear to tell keys apart in a list. Eight
  # characters past the marker — enough to identify one, nowhere near enough to
  # narrow a search for the rest.
  @display_length byte_size(@key_prefix) + 8

  # Least privilege: a key gets the scopes it was granted and nothing implied.
  #
  # `invoices:payment_links` is separate from `invoices:read` because a payment
  # link is a bearer URL — anyone holding it can open the customer's payment
  # page. An accounting system that reads invoices has no need of it; a CRM
  # that sends invoices to customers does.
  @scopes ~w(invoices:read invoices:write invoices:payment_links
             clients:read clients:write e_way_bills:read)

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

  @doc """
  Builds a new key, returning `{raw_key, changeset}`.

  The raw key is never written down; only its hash and a short display prefix
  are stored.
  """
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

  # Not `validate_length(min: 1)`: an empty list equals the field's default, so
  # casting `[]` records no change and a length validation never runs. A key
  # with no scopes would then be created — useless, and confusing to whoever
  # later wonders what it was for.
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
