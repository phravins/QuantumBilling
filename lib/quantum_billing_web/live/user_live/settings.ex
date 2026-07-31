defmodule QuantumBillingWeb.UserLive.Settings do
  @moduledoc """
  Account Settings: the signed-in user's own profile, password and 2FA.

  ## The re-authentication gate

  This page used to carry `on_mount {UserAuth, :require_sudo_mode}`, which
  redirected any visit more than ten minutes after sign-in straight to the login
  screen — you could not so much as look at your own name. The gate now sits on
  the two sensitive actions instead: changing the password or the email still
  demands a recent sign-in, and says so, while the profile fields are freely
  editable.

  Tabs live in a query parameter rather than a path segment.
  `/users/settings/:tab` would swallow the existing
  `/users/settings/confirm-email/:token` route.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Accounts

  @tabs [
    {:profile, "Profile", "hero-user"},
    {:password, "Change Password", "hero-lock-closed"},
    {:two_factor, "Two Factor Authentication", "hero-shield-check"}
  ]

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Account Settings")
     |> assign(:active_nav, :settings)
     |> assign(:current_email, user.email)
     |> assign(:trigger_submit, false)
     |> assign_forms(user)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :tab, tab_from(params["tab"]))}
  end

  defp tab_from(value) do
    Enum.find_value(@tabs, :profile, fn {key, _label, _icon} ->
      if to_string(key) == value, do: key
    end)
  end

  defp assign_forms(socket, user) do
    socket
    |> assign(:user, user)
    |> assign(:current_email, user.email)
    |> assign(:profile_form, to_form(Accounts.change_user_profile(user)))
    |> assign(:email_form, to_form(Accounts.change_user_email(user, %{}, validate_unique: false)))
    |> assign(
      :password_form,
      to_form(Accounts.change_user_password(user, %{}, hash_password: false))
    )
  end

  # ── Profile ────────────────────────────────────────────────────────────────
  # Display details, not identity — no re-authentication needed.

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset))}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    case Accounts.update_user_profile(socket.assigns.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign_forms(user)
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset))}
    end
  end

  # ── Email ──────────────────────────────────────────────────────────────────
  # Never applied directly: a link goes to the new address and must be clicked.

  def handle_event("validate_email", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_email(params, validate_unique: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :email_form, to_form(changeset))}
  end

  def handle_event("update_email", %{"user" => params}, socket) do
    user = socket.assigns.user

    if recently_signed_in?(user) do
      case Accounts.change_user_email(user, params) do
        %{valid?: true} = changeset ->
          Accounts.deliver_user_update_email_instructions(
            Ecto.Changeset.apply_action!(changeset, :insert),
            user.email,
            &url(~p"/users/settings/confirm-email/#{&1}")
          )

          {:noreply,
           put_flash(
             socket,
             :info,
             "A link to confirm your email change has been sent to the new address."
           )}

        changeset ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    else
      {:noreply, refuse_stale(socket)}
    end
  end

  # ── Password ───────────────────────────────────────────────────────────────

  def handle_event("validate_password", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.change_user_password(params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :password_form, to_form(changeset))}
  end

  def handle_event("update_password", %{"user" => params}, socket) do
    user = socket.assigns.user

    if recently_signed_in?(user) do
      case Accounts.change_user_password(user, params) do
        %{valid?: true} = changeset ->
          {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

        changeset ->
          {:noreply, assign(socket, :password_form, to_form(changeset, action: :insert))}
      end
    else
      {:noreply, refuse_stale(socket)}
    end
  end

  # Ten minutes, matching the window `UserAuth.on_mount(:require_sudo_mode)`
  # used before the gate moved here. `Accounts.sudo_mode?/2` defaults to twenty,
  # so relying on the default would quietly have doubled how long a stale
  # session could still change a password.
  defp recently_signed_in?(user), do: Accounts.sudo_mode?(user, -10)

  # Previously this was `true = Accounts.sudo_mode?(user)` behind a page-level
  # gate. With the gate moved onto the action, a bare match would crash the
  # LiveView instead of telling the user what to do about it.
  defp refuse_stale(socket) do
    put_flash(
      socket,
      :error,
      "For your security, sign in again before changing your email or password."
    )
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/45" aria-label="Breadcrumb">
        <.link navigate={~p"/settings"} class="hover:text-base-content">Settings</.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/60">Account Settings</span>
      </nav>

      <.header>
        Account Settings
        <:subtitle>Manage your personal information and sign-in security</:subtitle>
      </.header>

      <.card padding="p-0">
        <div class="flex items-center gap-1 overflow-x-auto border-b border-base-300 px-2">
          <.link
            :for={{key, label, icon} <- @tabs}
            patch={~p"/users/settings?#{[tab: key]}"}
            class={[
              "flex items-center gap-2 whitespace-nowrap border-b-2 px-3 py-3 text-sm transition-colors",
              if(@tab == key,
                do: "border-base-content font-medium text-base-content",
                else: "border-transparent text-base-content/60 hover:text-base-content"
              )
            ]}
          >
            <.icon name={icon} class="size-4" />{label}
          </.link>
        </div>

        <div class="p-6">
          {render_tab(assigns)}
        </div>
      </.card>
    </Layouts.app>
    """
  end

  defp render_tab(%{tab: :profile} = assigns) do
    ~H"""
    <h2 class="text-sm font-semibold tracking-tight">Profile Information</h2>
    <p class="mt-1 text-sm text-base-content/60">
      Update your personal information and contact details.
    </p>

    <.form
      for={@profile_form}
      id="profile_form"
      phx-change="validate_profile"
      phx-submit="save_profile"
      class="mt-5"
    >
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field field={@profile_form[:full_name]} label="Full Name" placeholder="Your name" />
        <.field
          field={@profile_form[:designation]}
          label="Designation"
          placeholder="e.g. GST Officer"
        />
        <.field field={@profile_form[:phone]} label="Phone Number" placeholder="+91 98765 43210" />
      </div>

      <button type="submit" class={[action_button_class(), "mt-5"]}>
        <.icon name="hero-check" class="size-4" /> Save Changes
      </button>
    </.form>

    <div class="mt-8 border-t border-base-300 pt-6">
      <h2 class="text-sm font-semibold tracking-tight">Profile Picture</h2>

      <div class="mt-3 flex flex-wrap items-center gap-4">
        <span class={[avatar_class(), "size-14 bg-base-300 text-base text-base-content"]}>
          {initials(@user)}
        </span>
        <div>
          <p class="text-sm text-base-content/60">
            Your initials are used until an image can be uploaded.
          </p>
          <span class="mt-2 inline-flex h-9 items-center gap-2 rounded-field border border-base-300 px-3 text-sm text-base-content/45">
            <.icon name="hero-photo" class="size-4" /> Uploading needs file storage
          </span>
        </div>
      </div>
    </div>

    <div class="mt-8 border-t border-base-300 pt-6">
      <h2 class="text-sm font-semibold tracking-tight">Email Address</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Changing this sends a confirmation link to the new address, so it saves on its own
        rather than with the rest of your profile.
      </p>

      <.form
        for={@email_form}
        id="email_form"
        phx-change="validate_email"
        phx-submit="update_email"
        class="mt-4"
      >
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.field
            field={@email_form[:email]}
            label="Email Address"
            type="email"
            autocomplete="username"
            required
          />
        </div>

        <button type="submit" class={[secondary_button_class(), "mt-4"]}>
          <.icon name="hero-envelope" class="size-4" /> Send confirmation link
        </button>
      </.form>
    </div>
    """
  end

  defp render_tab(%{tab: :password} = assigns) do
    ~H"""
    <h2 class="text-sm font-semibold tracking-tight">Change Password</h2>
    <p class="mt-1 text-sm text-base-content/60">
      Choose a strong password to keep your account secure. You may be asked to sign in
      again first.
    </p>

    <.form
      for={@password_form}
      id="password_form"
      action={~p"/users/update-password"}
      method="post"
      phx-change="validate_password"
      phx-submit="update_password"
      phx-trigger-action={@trigger_submit}
      class="mt-5"
    >
      <input
        name={@password_form[:email].name}
        type="hidden"
        id="hidden_user_email"
        spellcheck="false"
        value={@current_email}
      />

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <.field
          field={@password_form[:password]}
          label="New password"
          type="password"
          autocomplete="new-password"
          required
          hint="At least 8 characters."
        />
        <.field
          field={@password_form[:password_confirmation]}
          label="Confirm new password"
          type="password"
          autocomplete="new-password"
        />
      </div>

      <button type="submit" phx-disable-with="Saving..." class={[action_button_class(), "mt-5"]}>
        <.icon name="hero-lock-closed" class="size-4" /> Update Password
      </button>
    </.form>
    """
  end

  defp render_tab(%{tab: :two_factor} = assigns) do
    ~H"""
    <h2 class="text-sm font-semibold tracking-tight">Two Factor Authentication</h2>
    <p class="mt-1 text-sm text-base-content/60">
      Add an extra layer of security to your account.
    </p>

    <div class="mt-5 flex flex-col items-center px-6 py-12 text-center">
      <span class="mb-3 flex size-10 items-center justify-center rounded-full bg-base-200 text-base-content/45">
        <.icon name="hero-shield-check" class="size-4.5" />
      </span>
      <p class="text-sm font-medium">Two factor authentication is not available yet</p>
      <p class="mt-1 max-w-md text-sm text-base-content/60">
        Turning it on needs an authenticator secret stored against your account, a set of
        recovery codes, and a challenge step added to sign-in.
      </p>
    </div>
    """
  end

  # Initials from the name when there is one, otherwise from the email — the
  # same fallback the sidebar uses.
  defp initials(%{full_name: name}) when is_binary(name) and name != "" do
    case String.split(name, ~r/\s+/, trim: true) do
      [single] -> single |> String.slice(0, 2) |> String.upcase()
      [first, second | _] -> String.upcase(String.first(first) <> String.first(second))
    end
  end

  defp initials(%{email: email}) when is_binary(email) do
    email |> String.slice(0, 2) |> String.upcase()
  end

  defp initials(_user), do: "--"
end
