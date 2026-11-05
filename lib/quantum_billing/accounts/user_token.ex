defmodule QuantumBilling.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias QuantumBilling.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # Kept short: anyone with access to the mailbox could take over the account.
  @magic_link_validity_in_minutes 15
  @confirm_validity_in_days 7
  @change_email_validity_in_days 7
  @session_validity_in_days 14
  # Shorter than confirmation: this link sets a password.
  @reset_password_validity_in_hours 4

  @schema_prefix "public"
  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, QuantumBilling.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a session token. It is stored signed, so it isn't hashed.

  Tokens are kept in the database so individual sessions can be expired.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks a session token and returns a query for `{user, token_inserted_at}`.

  Valid if it matches the database and is younger than `@session_validity_in_days`.
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds an email token and its hash: the plain token is mailed, only the hash
  is stored. Tokens stop working if the user's email changes.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks a magic-link ("login") token and returns a query for `{user, token}`.
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc "Checks a sign-up confirmation token and returns a query for `{user, token}`."
  def verify_confirm_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "confirm"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(@confirm_validity_in_days, "day"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks a password-reset token and returns a query for `{user, token}`.

  `sent_to == user.email` means the link stops working if the email changes.
  """
  def verify_reset_password_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "reset_password"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(@reset_password_validity_in_hours, "hour"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks a change-email token (context `"change:..."`) and returns a query for the user_token.
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
