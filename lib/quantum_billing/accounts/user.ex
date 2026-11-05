defmodule QuantumBilling.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "public"
  schema "users" do
    field :username, :string
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    field :full_name, :string
    field :phone, :string
    field :designation, :string
    field :bio, :string
    # Set when the first-sign-in screens are finished or skipped; never cast.
    field :onboarded_at, :utc_datetime
    # Seeds the profile page's generated landscape; nil falls back to the id.
    field :banner_seed, :integer

    # The secret is encrypted at rest.
    field :totp_secret, QuantumBilling.Encrypted.Binary, redact: true
    field :totp_confirmed_at, :utc_datetime
    field :totp_last_used_at, :utc_datetime
    field :recovery_codes, {:array, :string}, default: [], redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for display details. Permissive: these are shown, not trusted, so any phone format is allowed.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:full_name, :phone, :designation, :bio])
    |> validate_length(:full_name, max: 120)
    |> validate_length(:bio, max: 500)
    |> validate_length(:designation, max: 80)
    |> validate_length(:phone, max: 30)
    |> validate_format(:phone, ~r/^[\d\s+()-]*$/,
      message: "may only contain digits, spaces and + ( ) -"
    )
  end

  @doc """
  A changeset for onboarding's "About you" step; name required. `onboarded_at` is never cast.
  """
  def onboarding_changeset(user, attrs) do
    user
    |> profile_changeset(attrs)
    |> cast(attrs, [:bio])
    |> update_change(:full_name, &trim/1)
    |> validate_required([:full_name], message: "tell us what to call you")
    |> validate_length(:bio, max: 500)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  @doc """
  A changeset for the profile banner's scene seed, and nothing else.
  """
  def banner_changeset(user, attrs) do
    user
    |> cast(attrs, [:banner_seed])
    |> validate_required([:banner_seed])
    |> validate_number(:banner_seed, greater_than: 0)
  end

  @doc """
  A changeset for registering or changing the email. The email must change.

  Options: `:validate_unique` (default `true`), set `false` for live validation.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, QuantumBilling.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A changeset for the username.

  Options: `:validate_unique` (default `true`), set `false` for live validation.
  """
  def username_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username])
    |> validate_username(opts)
  end

  defp validate_username(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:username])
      |> validate_format(:username, ~r/^[a-zA-Z0-9_.-]+$/,
        message: "may only contain letters, numbers, dots, dashes and underscores"
      )
      |> validate_length(:username, min: 3, max: 30)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:username, QuantumBilling.Repo)
      |> unique_constraint(:username)
    else
      changeset
    end
  end

  @doc """
  A changeset for registering with a username, email and password.

  Takes the options of `username_changeset/3`, `email_changeset/3` and `password_changeset/3`.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> username_changeset(attrs, opts)
    |> email_changeset(attrs, opts)
    |> password_changeset(attrs, opts)
  end

  @doc """
  A changeset for changing the password. Length is capped, since long passwords are costly to hash.

  Options: `:hash_password` (default `true`) hashes and clears the plain password;
  set `false` for live form validation.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashed here rather than in `prepare_changes/2`, which would hold the transaction open longer.
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc "Verifies the password. With no user, `Pbkdf2.no_user_verify/0` keeps the timing the same."
  def valid_password?(%QuantumBilling.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end
end
