defmodule QuantumBilling.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  require Logger

  alias QuantumBilling.Events
  alias QuantumBilling.Repo

  alias QuantumBilling.Accounts.{Invitation, User, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by id, or `nil`.

  Used where a missing user is an ordinary outcome rather than a bug — a
  half-finished sign-in whose account was deleted in the meantime, for example.
  """
  def get_user(id), do: Repo.get(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user with a username, an email and a password.

  The account starts unconfirmed: `deliver_user_confirmation_instructions/2`
  emails the link that confirms it, and password login is refused until then.

  ## Examples

      iex> register_user_with_password(%{username: value, email: value, password: value})
      {:ok, %User{}}

      iex> register_user_with_password(%{email: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user_with_password(attrs) do
    register_user_with_password(attrs, nil)
  end

  @doc """
  Registers a user with a username, an email and a password, if the
  installation will accept one.

  Registration is not open. This application bills for one business and shares
  one dataset between its accounts — there is no per-user scoping on invoices
  or clients, by design — so an account is full access to the books. Letting
  anyone create one meant a stranger could confirm their own email address and
  then read every invoice and client, export the whole database, and change the
  stored SMTP and payment credentials.

  Two ways in, and only two:

    * **the first account.** An empty `users` table accepts one registration,
      which becomes the owner. This is how a fresh install is set up, with no
      seeding step.

    * **an invitation.** Afterwards an owner invites an address, and only that
      address can register, once, before the invitation expires.

  The invitation is claimed in the same transaction that inserts the user, so
  two simultaneous submissions of one token cannot both succeed.
  """
  def register_user_with_password(attrs, invitation_token) do
    if bootstrap?() do
      %User{}
      |> User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:role, "owner")
      |> Repo.insert()
    else
      register_invited_user(attrs, invitation_token)
    end
  end

  defp register_invited_user(attrs, invitation_token) do
    case fetch_pending_invitation(invitation_token) do
      {:ok, invitation} ->
        insert_invited_user(attrs, invitation)

      {:error, reason} ->
        {:error, invitation_error(attrs, reason)}
    end
  end

  defp insert_invited_user(attrs, invitation) do
    Ecto.Multi.new()
    # Conditional claim: of two racing submissions, the second updates nothing and rolls back.
    |> Ecto.Multi.run(:claim, fn repo, _changes ->
      query =
        from(i in Invitation, where: i.id == ^invitation.id, where: is_nil(i.accepted_at))

      case repo.update_all(query,
             set: [accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
           ) do
        {1, _} -> {:ok, invitation}
        {0, _} -> {:error, :already_accepted}
      end
    end)
    |> Ecto.Multi.insert(:user, fn _changes ->
      %User{}
      |> User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:role, invitation.role)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      {:error, :claim, reason, _changes} -> {:error, invitation_error(attrs, reason)}
    end
  end

  # The account gets the invited email, not any address.
  defp fetch_pending_invitation(nil), do: {:error, :closed}
  defp fetch_pending_invitation(""), do: {:error, :closed}

  defp fetch_pending_invitation(token) when is_binary(token) do
    with {:ok, query} <- Invitation.by_token_query(token),
         %Invitation{} = invitation <- Repo.one(query) do
      {:ok, invitation}
    else
      _invalid -> {:error, :invalid_invitation}
    end
  end

  defp fetch_pending_invitation(_token), do: {:error, :closed}

  defp invitation_error(attrs, reason) do
    message =
      case reason do
        :closed ->
          "Registration on this installation is by invitation. Ask an owner to invite you."

        :already_accepted ->
          "That invitation has already been used."

        _invalid ->
          "That invitation link is invalid or has expired."
      end

    %User{}
    |> User.registration_changeset(attrs, hash_password: false, validate_unique: false)
    |> Map.put(:action, :insert)
    |> Ecto.Changeset.add_error(:email, message)
  end

  @doc """
  Whether this installation is still waiting for its first account.

  True only while `users` is empty. Checked rather than cached: a cached
  "closed" flag that went stale would either lock out a fresh install or
  reopen registration on a live one.
  """
  def bootstrap?, do: not Repo.exists?(User)

  @doc """
  Whether a stranger can register right now.

  The sign-up page asks this to decide between showing the form and explaining
  that an invitation is needed.
  """
  def registration_open?(invitation_token \\ nil) do
    bootstrap?() or match?({:ok, _}, fetch_pending_invitation(invitation_token))
  end

  @doc """
  The address an invitation was issued to, or `nil`.

  The sign-up form pre-fills and locks the email from this, so the person
  cannot accidentally register the wrong address and burn the invitation.
  """
  def invited_email(invitation_token) do
    case fetch_pending_invitation(invitation_token) do
      {:ok, invitation} -> invitation.email
      {:error, _reason} -> nil
    end
  end

  ## Accounts and invitations — owner administration

  @doc "Every account, oldest first, for the owner's user list."
  def list_users do
    Repo.all(from u in User, order_by: [asc: u.inserted_at, asc: u.id])
  end

  @doc "How many owners the installation has."
  def count_owners do
    Repo.aggregate(from(u in User, where: u.role == "owner"), :count, :id)
  end

  @doc """
  Grants `role` to `user`.

  Refuses to demote the last owner: an installation with no owner has nobody
  who can invite, administer credentials or export the data, and no way back
  short of a console.
  """
  def set_role(%User{} = user, role) when is_binary(role) do
    cond do
      user.role == role ->
        {:ok, user}

      user.role == "owner" and role != "owner" and count_owners() <= 1 ->
        {:error, :last_owner}

      true ->
        user
        |> User.role_changeset(role)
        |> Repo.update()
    end
  end

  @doc "Pending and recent invitations, newest first."
  def list_invitations do
    Repo.all(
      from i in Invitation,
        order_by: [desc: i.inserted_at, desc: i.id],
        preload: [:invited_by]
    )
  end

  @doc """
  Invites `email` to create an account, and emails them the link.

  Re-inviting an address replaces its pending invitation rather than leaving
  two live tokens for one mailbox — the partial unique index enforces that, and
  this deletes the old one first so re-sending is not an error.

  Returns `{:ok, invitation}`; the raw token only ever exists inside this
  function and the email it sends. When the relay refuses the email, returns
  `{:error, {:delivery_failed, message}}` and no invitation is left pending.
  """
  def invite(email, role, %User{} = invited_by, url_fun) when is_function(url_fun, 1) do
    normalized = email |> to_string() |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:error, :invalid_email}

      get_user_by_email(normalized) ->
        {:error, :already_registered}

      true ->
        {token, changeset} = Invitation.build(normalized, role, invited_by)

        with {:ok, invitation} <- replace_pending_invitation(normalized, changeset) do
          send_invitation(invitation, url_fun.(token))
        end
    end
  end

  defp replace_pending_invitation(email, changeset) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from i in Invitation, where: i.email == ^email, where: is_nil(i.accepted_at)
      )

      case Repo.insert(changeset) do
        {:ok, invitation} -> invitation
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Sent after commit so a failure stays in the delivery ledger.
  # An invitation whose email was refused is withdrawn.
  defp send_invitation(invitation, url) do
    case UserNotifier.deliver_invitation(invitation, url) do
      {:ok, _email} ->
        {:ok, invitation}

      {:error, message} ->
        Repo.delete(invitation)
        {:error, {:delivery_failed, message}}
    end
  end

  @doc "Withdraws a pending invitation."
  def revoke_invitation(%Invitation{} = invitation), do: Repo.delete(invitation)

  @doc "Fetches an invitation by id, or `nil`."
  def get_invitation(id), do: Repo.get(Invitation, id)

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking the registration form.

  Neither hashes the password nor hits the database for the uniqueness check, so
  it is safe to run on every keystroke.

  ## Examples

      iex> change_user_registration(%User{})
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_unique: false)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for the user's display details.

  ## Examples

      iex> change_user_profile(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  @doc """
  Updates the user's display details.

  Unlike the email and password, these are not identity and need no
  confirmation or re-authentication.

  ## Examples

      iex> update_user_profile(user, %{full_name: "Priya Sharma"})
      {:ok, %User{}}

  """
  def update_user_profile(%User{} = user, attrs) do
    result =
      user
      |> User.profile_changeset(attrs)
      |> Repo.update()

    with {:ok, saved} <- result do
      Events.broadcast(Events.user_topic(saved.id), {:profile_updated, saved})
    end

    result
  end

  @doc """
  Subscribes the caller to changes to `user`'s own account.
  """
  def subscribe_user(%User{id: id}), do: Events.subscribe(Events.user_topic(id))

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `QuantumBilling.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `QuantumBilling.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc ~S"""
  Delivers the sign-up confirmation link to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_confirmation_instructions(%User{} = user, confirm_url_fun)
      when is_function(confirm_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
    Repo.insert!(user_token)
    UserNotifier.deliver_confirmation_instructions(user, confirm_url_fun.(encoded_token))
  end

  @doc ~S"""
  Emails a password reset link to the account registered at `email`.

  Always returns `:ok`, whatever the address turns out to be. Reporting "no
  such account" here would turn the form into a way to ask which addresses hold
  accounts, so the caller cannot tell an unknown address from a known one — and
  neither can anyone else.

  Unconfirmed accounts are included on purpose: following a link sent to the
  address proves the same thing confirmation does, so `reset_user_password/2`
  confirms the account as it sets the password.

  ## Examples

      iex> deliver_user_reset_password_instructions("someone@example.com", &url(~p"/users/reset-password/#{&1}"))
      :ok

  """
  def deliver_user_reset_password_instructions(email, reset_url_fun)
      when is_binary(email) and is_function(reset_url_fun, 1) do
    case get_user_by_email(email) do
      %User{} = user ->
        {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
        Repo.insert!(user_token)

        case UserNotifier.deliver_reset_password_instructions(
               user,
               reset_url_fun.(encoded_token)
             ) do
          {:ok, _email} ->
            :ok

          {:error, reason} ->
            Logger.warning("password reset email to #{user.email} failed: #{inspect(reason)}")
            :ok
        end

      nil ->
        :ok
    end
  end

  @doc """
  The user a password reset token belongs to, or `nil` when the token is
  unknown, expired, or was sent to an address the account no longer uses.
  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         {%User{} = user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Sets a new password from the "forgot password" link.

  Every outstanding token is expired on success, so the link is single-use and
  any session opened with the old password is signed out — if the reset was
  prompted by someone else being in the account, leaving their session alive
  would defeat the point.

  The account is confirmed at the same time: the link only arrives by email, so
  following it proves the address as well as a confirmation link would.
  """
  def reset_user_password(%User{} = user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> User.confirm_changeset()
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Confirms a user from the token emailed at sign-up.

  Every outstanding token is expired on success, so the confirmation link can
  only be spent once.
  """
  def confirm_user_by_token(token) do
    with {:ok, query} <- UserToken.verify_confirm_token_query(token),
         {%User{} = user, _token} <- Repo.one(query),
         {:ok, {user, _expired_tokens}} <-
           user |> User.confirm_changeset() |> update_user_and_delete_all_tokens() do
      {:ok, user}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
