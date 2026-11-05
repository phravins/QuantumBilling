defmodule QuantumBilling.Accounts do
  @moduledoc "Users, registration, sessions, memberships and invitations."

  import Ecto.Query, warn: false

  require Logger

  alias QuantumBilling.Events
  alias QuantumBilling.Repo

  alias QuantumBilling.Accounts.{Invitation, User, UserToken, UserNotifier}
  alias QuantumBilling.Businesses
  alias QuantumBilling.Businesses.{Business, Membership}

  @doc "Gets a user by email."
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc "Gets a user by email and password."
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc "Gets a user by id. Raises if missing."
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Gets a user by id, or `nil`."
  def get_user(id), do: Repo.get(User, id)

  @doc "Registers a user."
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Registers a user with a username, email and password. The account starts unconfirmed."
  def register_user_with_password(attrs) do
    register_user_with_password(attrs, nil)
  end

  @doc """
  Registers a user, if the installation accepts one.

  Only two ways in: the first account on an empty install (it becomes the
  owner), or an invitation for that exact address. The invitation is claimed in
  the same transaction as the insert, so a token cannot be used twice.
  """
  def register_user_with_password(attrs, invitation_token) do
    if bootstrap?() do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
      |> Ecto.Multi.run(:membership, fn _repo, %{user: user} ->
        Businesses.put_membership(user, Businesses.default!(), "owner")
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, :user, changeset, _changes} -> {:error, changeset}
      end
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
    # Of two racing submissions, the second updates nothing and rolls back.
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
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Ecto.Multi.run(:memberships, fn repo, %{user: user} ->
      {:ok, join_invited_businesses(repo, user, invitation)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      {:error, :claim, reason, _changes} -> {:error, invitation_error(attrs, reason)}
    end
  end

  # Claims every pending invitation for this address, across businesses.
  defp join_invited_businesses(repo, user, invitation) do
    now = DateTime.utc_now(:second)

    others =
      repo.all(
        from i in Invitation,
          where: i.email == ^user.email and i.id != ^invitation.id,
          where: is_nil(i.accepted_at) and i.expires_at > ^now
      )

    repo.update_all(from(i in Invitation, where: i.id in ^Enum.map(others, & &1.id)),
      set: [accepted_at: now]
    )

    for %Invitation{business_id: business_id, role: role} <- [invitation | others] do
      {:ok, membership} =
        %Membership{user_id: user.id, business_id: business_id}
        |> Membership.changeset(role)
        |> repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :business_id])

      membership
    end
  end

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

  @doc "Whether the install has no users yet. Checked, never cached."
  def bootstrap?, do: not Repo.exists?(User)

  @doc "Whether a stranger can register right now."
  def registration_open?(invitation_token \\ nil) do
    bootstrap?() or match?({:ok, _}, fetch_pending_invitation(invitation_token))
  end

  @doc "The address an invitation was issued to, or `nil`."
  def invited_email(invitation_token) do
    case fetch_pending_invitation(invitation_token) do
      {:ok, invitation} -> invitation.email
      {:error, _reason} -> nil
    end
  end

  @doc "Everyone in `business`, oldest account first, as memberships with their user."
  def list_members(%Business{id: business_id}) do
    Repo.all(
      from m in Membership,
        join: u in assoc(m, :user),
        where: m.business_id == ^business_id,
        order_by: [asc: u.inserted_at, asc: u.id],
        preload: [user: u]
    )
  end

  @doc "How many owners `business` has."
  def count_owners(%Business{id: business_id}) do
    Repo.aggregate(
      from(m in Membership, where: m.business_id == ^business_id and m.role == "owner"),
      :count,
      :id
    )
  end

  @doc "Gives `user` the role `role` in `business`. Refuses to demote the last owner."
  def set_role(%Business{} = business, %User{} = user, role) when is_binary(role) do
    case Repo.get_by(Membership, user_id: user.id, business_id: business.id) do
      nil ->
        {:error, :not_a_member}

      %Membership{role: ^role} = membership ->
        {:ok, membership}

      %Membership{role: "owner"} = membership ->
        if count_owners(business) <= 1,
          do: {:error, :last_owner},
          else: change_role(membership, role)

      membership ->
        change_role(membership, role)
    end
  end

  defp change_role(membership, role) do
    membership
    |> Membership.changeset(role)
    |> Repo.update()
  end

  @doc "Removes `user` from `business`. Refuses to remove the last owner."
  def remove_member(%Business{} = business, %User{} = user) do
    case Repo.get_by(Membership, user_id: user.id, business_id: business.id) do
      nil ->
        {:error, :not_a_member}

      %Membership{role: "owner"} = membership ->
        if count_owners(business) <= 1,
          do: {:error, :last_owner},
          else: Repo.delete(membership)

      membership ->
        Repo.delete(membership)
    end
  end

  @doc "`business`'s pending and recent invitations, newest first."
  def list_invitations(%Business{id: business_id}) do
    Repo.all(
      from i in Invitation,
        where: i.business_id == ^business_id,
        order_by: [desc: i.inserted_at, desc: i.id],
        preload: [:invited_by]
    )
  end

  @doc """
  Brings `email` into `business` as `role`.

  Returns `{:ok, {:added, membership}}` for an existing account, or
  `{:ok, {:invited, invitation}}` after emailing an invitation. Re-inviting
  replaces the pending invitation. Returns `{:error, {:delivery_failed, msg}}`
  if the email is refused.
  """
  def invite(%Business{} = business, email, role, %User{} = invited_by, url_fun)
      when is_function(url_fun, 1) do
    normalized = email |> to_string() |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:error, :invalid_email}

      user = get_user_by_email(normalized) ->
        add_existing_user(business, user, role)

      true ->
        {token, changeset} = Invitation.build(normalized, role, invited_by, business)

        with {:ok, invitation} <- replace_pending_invitation(business, normalized, changeset),
             {:ok, invitation} <- send_invitation(invitation, url_fun.(token)) do
          {:ok, {:invited, invitation}}
        end
    end
  end

  defp add_existing_user(business, user, role) do
    if Businesses.get_membership(user, business.id) do
      {:error, :already_member}
    else
      %Membership{user_id: user.id, business_id: business.id}
      |> Membership.changeset(role)
      |> Repo.insert()
      |> case do
        {:ok, membership} -> {:ok, {:added, %{membership | user: user}}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp replace_pending_invitation(business, email, changeset) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from i in Invitation,
          where: i.business_id == ^business.id and i.email == ^email,
          where: is_nil(i.accepted_at)
      )

      case Repo.insert(changeset) do
        {:ok, invitation} -> invitation
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Sent after commit so failures land in the delivery ledger; a refused invitation is withdrawn.
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

  @doc "`business`'s invitation with `id`, or `nil`."
  def get_invitation(%Business{id: business_id}, id),
    do: Repo.get_by(Invitation, id: id, business_id: business_id)

  @doc "A registration changeset. No hashing or DB check, so safe on every keystroke."
  def change_user_registration(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false, validate_unique: false)
  end

  @doc "Whether the user authenticated within the last `minutes` (default 20)."
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc "A changeset for the user's display details."
  def change_user_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  @doc "Updates the user's display details."
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
  A changeset for onboarding's "About you" step.
  """
  def change_onboarding(%User{} = user, attrs \\ %{}) do
    User.onboarding_changeset(user, attrs)
  end

  @doc """
  Saves the "About you" step without finishing onboarding.
  """
  def save_onboarding_profile(%User{} = user, attrs) do
    user
    |> User.onboarding_changeset(attrs)
    |> Repo.update()
    |> broadcast_profile()
  end

  @doc "Marks onboarding finished or skipped. Idempotent."
  def complete_onboarding(%User{onboarded_at: %DateTime{}} = user), do: {:ok, user}

  def complete_onboarding(%User{} = user) do
    user
    |> Ecto.Changeset.change(onboarded_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> broadcast_profile()
  end

  @doc "Whether `user` still has the first-sign-in screens to see."
  def onboarding_pending?(%User{onboarded_at: nil}), do: true
  def onboarding_pending?(_user), do: false

  defp broadcast_profile({:ok, saved} = result) do
    Events.broadcast(Events.user_topic(saved.id), {:profile_updated, saved})
    result
  end

  defp broadcast_profile(error), do: error

  @doc "Gives the profile banner a new scene and broadcasts the change."
  def shuffle_banner(%User{} = user) do
    result =
      user
      |> User.banner_changeset(%{banner_seed: :rand.uniform(2_147_483_647)})
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

  @doc "A changeset for changing the email."
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc "Updates the email with the given token, then deletes the token."
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

  @doc "A changeset for changing the password."
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc "Updates the password. Returns the user and the expired tokens."
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc "Every session token `user` holds, as `%{token: binary}` maps for disconnecting them."
  def list_user_session_tokens(%User{id: user_id}) do
    Repo.all(
      from t in UserToken,
        where: t.user_id == ^user_id and t.context == "session",
        select: %{token: t.token}
    )
  end

  @doc "Gets `{user, token_inserted_at}` for a signed token, or `nil`."
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

  A confirmed user is logged in and the link expires. An unconfirmed user with
  no password is confirmed and all their tokens expire. An unconfirmed user with
  a password is refused (session fixation).
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
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
            Logger.warning("password reset email to user #{user.id} failed: #{inspect(reason)}")
            :ok
        end

      nil ->
        :ok
    end
  end

  @doc "The user a password reset token belongs to, or `nil`."
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         {%User{} = user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc "Sets a new password from a reset link, expires every token and confirms the account."
  def reset_user_password(%User{} = user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> User.confirm_changeset()
    |> update_user_and_delete_all_tokens()
  end

  @doc "Confirms a user from the sign-up token and expires every token."
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
