defmodule QuantumBillingWeb.UserLive.Settings do
  @moduledoc """
  Account settings: the user's profile, password, email and 2FA.

  Only password and email changes need a recent sign-in. Tabs use a query
  parameter, since `/users/settings/:tab` would clash with `confirm-email/:token`.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Accounts
  alias QuantumBilling.Accounts.TwoFactor

  @tabs [
    {:profile, "Profile", "hero-user", "Name, role and contact"},
    {:email, "Email", "hero-envelope", "Your sign-in address"},
    {:password, "Password", "hero-lock-closed", "Change how you sign in"},
    {:two_factor, "Two-factor", "hero-shield-check", "Codes from your phone"}
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
     |> assign(:new_recovery_codes, nil)
     |> assign(:totp_error, nil)
     |> assign_forms(user)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :tab, tab_from(params["tab"]))}
  end

  defp tab_from(value) do
    Enum.find_value(@tabs, :profile, fn {key, _label, _icon, _hint} ->
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

  # ── Profile ──

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

  # ── Email ──
  # Never applied directly: the new address must confirm a link.

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

  # ── Two factor ──
  # Behind the same recent-sign-in check as password and email.

  def handle_event("start_totp_enrolment", _params, socket) do
    user = socket.assigns.user

    if recently_signed_in?(user) do
      {:ok, user} = TwoFactor.start_enrolment(user)
      {:noreply, socket |> assign_forms(user) |> assign(:totp_error, nil)}
    else
      {:noreply, refuse_stale(socket)}
    end
  end

  def handle_event("cancel_totp_enrolment", _params, socket) do
    {:ok, user} = TwoFactor.disable(socket.assigns.user)
    {:noreply, socket |> assign_forms(user) |> assign(:totp_error, nil)}
  end

  def handle_event("confirm_totp", %{"totp" => %{"code" => code}}, socket) do
    user = socket.assigns.user

    if recently_signed_in?(user) do
      case TwoFactor.confirm_enrolment(user, code) do
        {:ok, user, codes} ->
          {:noreply,
           socket
           |> assign_forms(user)
           |> assign(:new_recovery_codes, codes)
           |> assign(:totp_error, nil)
           |> put_flash(:info, "Two-factor authentication is on.")}

        {:error, _reason} ->
          {:noreply,
           assign(
             socket,
             :totp_error,
             "That code is not valid. Check your authenticator app and try again."
           )}
      end
    else
      {:noreply, refuse_stale(socket)}
    end
  end

  def handle_event("regenerate_recovery_codes", _params, socket) do
    user = socket.assigns.user

    if recently_signed_in?(user) do
      {:ok, user, codes} = TwoFactor.regenerate_recovery_codes(user)

      {:noreply,
       socket
       |> assign_forms(user)
       |> assign(:new_recovery_codes, codes)
       |> put_flash(:info, "New recovery codes issued. The old ones no longer work.")}
    else
      {:noreply, refuse_stale(socket)}
    end
  end

  def handle_event("disable_totp", _params, socket) do
    user = socket.assigns.user

    if recently_signed_in?(user) do
      {:ok, user} = TwoFactor.disable(user)
      QuantumBilling.SecurityAlerts.two_factor_disabled(user)

      {:noreply,
       socket
       |> assign_forms(user)
       |> assign(:new_recovery_codes, nil)
       |> put_flash(:info, "Two-factor authentication is off.")}
    else
      {:noreply, refuse_stale(socket)}
    end
  end

  def handle_event("dismiss_recovery_codes", _params, socket) do
    {:noreply, assign(socket, :new_recovery_codes, nil)}
  end

  # Ten minutes; the sudo_mode?/2 default is twenty.
  defp recently_signed_in?(user), do: Accounts.sudo_mode?(user, -10)

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
    assigns =
      assigns
      |> assign(:tabs, @tabs)
      |> assign(:two_factor_on?, TwoFactor.enabled?(assigns.user))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/45" aria-label="Breadcrumb">
        <.link navigate={~p"/settings"} class="hover:text-base-content">Settings</.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/60">Account Settings</span>
      </nav>

      <.header>
        Account Settings
        <:subtitle>Manage your personal information and sign-in security</:subtitle>
      </.header>

      <section
        id="account-identity"
        class="mb-6 overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <div class="h-14 bg-linear-to-r from-primary/15 via-primary/5 to-transparent" />
        <div class="-mt-7 flex flex-col gap-4 px-5 pb-5 sm:flex-row sm:items-end sm:px-6">
          <%!-- current_scope, kept in step by the on_mount hook. --%>
          <span class={[
            avatar_class(),
            "size-16 shrink-0 bg-base-content text-lg font-semibold text-base-100 ring-4 ring-base-100"
          ]}>
            {initials(@current_scope.user)}
          </span>

          <div class="min-w-0 flex-1">
            <p class="truncate text-base font-semibold tracking-tight">
              {@user.full_name || @current_email}
            </p>
            <p class="truncate text-sm text-base-content/60">
              {@current_email}
              <span :if={@user.designation not in [nil, ""]}>· {@user.designation}</span>
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <span
              id="account-2fa-badge"
              class={[
                "inline-flex h-7 items-center gap-1.5 rounded-full px-2.5 text-xs font-medium",
                if(@two_factor_on?,
                  do: "bg-success/12 text-success",
                  else: "bg-warning/15 text-warning"
                )
              ]}
            >
              <.icon
                name={if(@two_factor_on?, do: "hero-shield-check", else: "hero-shield-exclamation")}
                class="size-3.5"
              />
              {if(@two_factor_on?, do: "Two-factor on", else: "Two-factor off")}
            </span>

            <.link id="view-profile" navigate={~p"/users/profile"} class={secondary_button_class()}>
              <.icon name="hero-user-circle" class="size-4" /> View profile
            </.link>
          </div>
        </div>
      </section>

      <div class="grid flex-1 grid-cols-1 items-start gap-6 lg:grid-cols-[15rem_minmax(0,1fr)]">
        <%!-- Scrolling tabs on a phone, a sticky column on a wide screen. --%>
        <nav
          id="account-nav"
          aria-label="Account sections"
          class="-mx-4 overflow-x-auto px-4 lg:sticky lg:top-4 lg:mx-0 lg:overflow-visible lg:px-0"
        >
          <div class="flex min-w-max gap-1 border-b border-base-300 lg:min-w-0 lg:flex-col lg:border-0">
            <.link
              :for={{key, label, icon, hint} <- @tabs}
              id={"account-tab-#{key}"}
              patch={~p"/users/settings?#{[tab: key]}"}
              aria-current={@tab == key && "page"}
              class={[
                "group relative flex items-center gap-3 whitespace-nowrap px-3 text-sm transition-colors duration-150",
                "-mb-px border-b-2 py-2.5 lg:mb-0 lg:rounded-field lg:border-b-0 lg:py-2",
                if(@tab == key,
                  do: "border-base-content font-medium text-base-content lg:bg-base-200",
                  else:
                    "border-transparent text-base-content/60 hover:text-base-content lg:hover:bg-base-200/60"
                )
              ]}
            >
              <span
                :if={@tab == key}
                class="absolute inset-y-2 left-0 hidden w-0.5 rounded-full bg-primary lg:block"
              />
              <.icon
                name={icon}
                class={[
                  "size-4 shrink-0 transition-colors",
                  if(@tab == key, do: "text-primary", else: "text-base-content/45")
                ]}
              />
              <span class="min-w-0">
                <span class="block">{label}</span>
                <span class="hidden truncate text-xs font-normal text-base-content/50 lg:block">
                  {hint}
                </span>
              </span>
            </.link>
          </div>
        </nav>

        <div id={"account-panel-#{@tab}"} class="flex min-w-0 flex-col gap-6">
          {render_tab(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block, required: true
  slot :footer

  defp section_card(assigns) do
    ~H"""
    <section id={@id} class="overflow-hidden rounded-box border border-base-300 bg-base-100">
      <header class="border-b border-base-300 px-5 py-4 sm:px-6">
        <h2 class="text-sm font-semibold tracking-tight">{@title}</h2>
        <p :if={@description} class="mt-1 text-sm text-base-content/60">{@description}</p>
      </header>

      <div class="px-5 py-5 sm:px-6">
        {render_slot(@inner_block)}
      </div>

      <footer
        :if={@footer != []}
        class="flex flex-wrap items-center justify-end gap-2 border-t border-base-300 bg-base-200/40 px-5 py-3 sm:px-6"
      >
        {render_slot(@footer)}
      </footer>
    </section>
    """
  end

  defp render_tab(%{tab: :profile} = assigns) do
    ~H"""
    <.form
      for={@profile_form}
      id="profile_form"
      phx-change="validate_profile"
      phx-submit="save_profile"
    >
      <.section_card
        id="account-profile"
        title="Profile Information"
        description="Update your personal information and contact details."
      >
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.field field={@profile_form[:full_name]} label="Full Name" placeholder="Your name" />
          <.field
            field={@profile_form[:designation]}
            label="Designation"
            placeholder="e.g. GST Officer"
          />
          <.field field={@profile_form[:phone]} label="Phone Number" placeholder="+91 98765 43210" />
          <div class="sm:col-span-2">
            <.field
              field={@profile_form[:bio]}
              label="Bio"
              type="textarea"
              rows="3"
              placeholder="A line or two about what you do"
              hint="Up to 500 characters. Shown on your profile."
            />
          </div>
        </div>

        <:footer>
          <button
            type="submit"
            id="save-profile"
            phx-disable-with="Saving..."
            class={action_button_class()}
          >
            <.icon name="hero-check" class="size-4" /> Save Changes
          </button>
        </:footer>
      </.section_card>
    </.form>

    <.section_card
      id="account-picture"
      title="Profile Picture"
      description="Shown beside your name across the app."
    >
      <div class="flex flex-wrap items-center gap-4">
        <span class={[avatar_class(), "size-14 bg-base-300 text-base text-base-content"]}>
          {initials(@current_scope.user)}
        </span>

        <div class="min-w-0 flex-1">
          <p class="text-sm text-base-content/70">
            Your initials are used until an image can be uploaded.
          </p>
          <p class="mt-1 inline-flex items-center gap-1.5 text-xs text-base-content/45">
            <.icon name="hero-photo" class="size-3.5" /> Uploading needs file storage
          </p>
        </div>
      </div>
    </.section_card>
    """
  end

  defp render_tab(%{tab: :email} = assigns) do
    ~H"""
    <.form for={@email_form} id="email_form" phx-change="validate_email" phx-submit="update_email">
      <.section_card
        id="account-email"
        title="Email Address"
        description="You sign in with this address. A change only takes effect once the new address confirms a link."
      >
        <div class="mb-4 flex items-center gap-3 rounded-field border border-base-300 bg-base-200/50 px-3.5 py-2.5">
          <.icon name="hero-envelope" class="size-4 shrink-0 text-base-content/45" />
          <div class="min-w-0">
            <p class="text-2xs uppercase tracking-wide text-base-content/50">Current address</p>
            <p class="truncate text-sm font-medium">{@current_email}</p>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.field
            field={@email_form[:email]}
            label="New email address"
            type="email"
            autocomplete="username"
            required
          />
        </div>

        <:footer>
          <button type="submit" id="send-email-link" class={action_button_class()}>
            <.icon name="hero-paper-airplane" class="size-4" /> Send confirmation link
          </button>
        </:footer>
      </.section_card>
    </.form>
    """
  end

  defp render_tab(%{tab: :password} = assigns) do
    ~H"""
    <.form
      for={@password_form}
      id="password_form"
      action={~p"/users/update-password"}
      method="post"
      phx-change="validate_password"
      phx-submit="update_password"
      phx-trigger-action={@trigger_submit}
    >
      <.section_card
        id="account-password"
        title="Change Password"
        description="Choose a strong password to keep your account secure. You may be asked to sign in again first."
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

        <ul class="mt-4 grid gap-1.5 text-xs text-base-content/55 sm:grid-cols-2">
          <li class="flex items-center gap-1.5">
            <.icon name="hero-check-circle" class="size-3.5 text-base-content/35" />
            A passphrase of a few words is easy to remember
          </li>
          <li class="flex items-center gap-1.5">
            <.icon name="hero-check-circle" class="size-3.5 text-base-content/35" />
            Don't reuse a password from another site
          </li>
        </ul>

        <:footer>
          <button
            type="submit"
            id="update-password"
            phx-disable-with="Saving..."
            class={action_button_class()}
          >
            <.icon name="hero-lock-closed" class="size-4" /> Update Password
          </button>
        </:footer>
      </.section_card>
    </.form>
    """
  end

  defp render_tab(%{tab: :two_factor} = assigns) do
    assigns = assign(assigns, :pending?, TwoFactor.pending?(assigns.user))

    ~H"""
    <%!-- Shown once: they are stored hashed. --%>
    <div
      :if={@new_recovery_codes}
      id="recovery-codes"
      class="rounded-box border border-warning/40 bg-warning/8 p-5"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="flex items-start gap-3">
          <.icon name="hero-key" class="mt-0.5 size-5 shrink-0 text-warning" />
          <div>
            <p class="text-sm font-semibold tracking-tight">Save your recovery codes</p>

            <p class="mt-1 text-sm text-base-content/60">
              Each one works once, and they are the only way in if you lose your device.
              <strong class="font-medium text-base-content">
                They will not be shown again.
              </strong>
            </p>
          </div>
        </div>

        <button
          type="button"
          phx-click="dismiss_recovery_codes"
          class={row_action_class()}
          aria-label="Dismiss recovery codes"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <ul class="mt-4 grid grid-cols-2 gap-2 font-mono text-sm sm:grid-cols-3">
        <li
          :for={code <- @new_recovery_codes}
          class="rounded-field border border-base-300 bg-base-100 px-3 py-1.5 text-center"
        >
          {code}
        </li>
      </ul>
    </div>

    <.section_card
      id="account-two-factor"
      title="Two Factor Authentication"
      description="Add an extra layer of security to your account."
    >
      <div
        id="two-factor-status"
        class={[
          "flex items-start gap-3 rounded-field border px-4 py-3",
          cond do
            @two_factor_on? -> "border-success/30 bg-success/8"
            @pending? -> "border-info/30 bg-info/8"
            true -> "border-warning/35 bg-warning/8"
          end
        ]}
      >
        <span class={[
          "flex size-9 shrink-0 items-center justify-center rounded-full",
          cond do
            @two_factor_on? -> "bg-success/15 text-success"
            @pending? -> "bg-info/15 text-info"
            true -> "bg-warning/15 text-warning"
          end
        ]}>
          <.icon
            name={
              cond do
                @two_factor_on? -> "hero-shield-check"
                @pending? -> "hero-device-phone-mobile"
                true -> "hero-shield-exclamation"
              end
            }
            class="size-5"
          />
        </span>

        <div class="min-w-0">
          <%= cond do %>
            <% @two_factor_on? -> %>
              <p class="text-sm font-semibold">Protected</p>
              <p class="text-sm text-base-content/60">
                Codes are required whenever you sign in. {TwoFactor.recovery_codes_remaining(@user)} recovery codes remain.
              </p>
            <% @pending? -> %>
              <p class="text-sm font-semibold">Almost there</p>
              <p class="text-sm text-base-content/60">
                Link your authenticator app below to finish.
              </p>
            <% true -> %>
              <p class="text-sm font-semibold">Not protected</p>
              <p class="text-sm text-base-content/60">
                With this on, signing in asks for a code from your phone as well as your password.
              </p>
          <% end %>
        </div>
      </div>

      <ol :if={@pending?} class="mt-5 space-y-5">
        <li class="flex gap-3">
          <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-xs font-semibold">
            1
          </span>
          <div>
            <p class="text-sm font-medium">Scan this with your authenticator app</p>
            <p class="mt-1 text-sm text-base-content/60">
              Google Authenticator, Microsoft Authenticator, 1Password and others all work.
            </p>
            <%!-- Literally white so the QR stays readable on a dark theme. --%>
            <div class="mt-3 w-fit rounded-box border border-base-300 bg-white p-3">
              {Phoenix.HTML.raw(TwoFactor.qr_svg(@user))}
            </div>
          </div>
        </li>

        <li class="flex gap-3">
          <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-xs font-semibold">
            2
          </span>
          <div class="min-w-0">
            <p class="text-sm font-medium">Or enter this key by hand</p>
            <p class="mt-2 w-fit max-w-full break-all rounded-field border border-base-300 bg-base-200 px-3 py-2 font-mono text-sm">
              {TwoFactor.manual_entry_key(@user)}
            </p>
          </div>
        </li>

        <li class="flex gap-3">
          <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-xs font-semibold">
            3
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-sm font-medium">Enter the 6-digit code it shows</p>

            <.form for={%{}} as={:totp} id="totp_form" phx-submit="confirm_totp" class="mt-3">
              <div class="flex flex-wrap items-start gap-2">
                <input
                  type="text"
                  id="totp_code"
                  name="totp[code]"
                  inputmode="numeric"
                  pattern="[0-9]*"
                  maxlength="6"
                  autocomplete="one-time-code"
                  placeholder="000000"
                  aria-label="6-digit code"
                  required
                  class={[form_input_class(), "w-36 text-center tracking-[0.3em]"]}
                />
                <button type="submit" class={action_button_class()}>
                  <.icon name="hero-check" class="size-4" /> Verify and turn on
                </button>

                <button
                  type="button"
                  phx-click="cancel_totp_enrolment"
                  class={secondary_button_class()}
                >
                  Cancel
                </button>
              </div>

              <p :if={@totp_error} class="mt-2 flex items-center gap-1 text-2xs text-error">
                <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />{@totp_error}
              </p>
            </.form>
          </div>
        </li>
      </ol>

      <:footer :if={not @pending?}>
        <%= if @two_factor_on? do %>
          <button
            type="button"
            phx-click="regenerate_recovery_codes"
            class={secondary_button_class()}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Issue new recovery codes
          </button>

          <button
            type="button"
            phx-click="disable_totp"
            data-confirm="Turn off two-factor authentication? Your recovery codes will stop working."
            class={[
              "inline-flex h-9 items-center gap-2 rounded-field px-3 text-sm text-error/85",
              "transition-colors hover:bg-error/10 hover:text-error"
            ]}
          >
            <.icon name="hero-shield-exclamation" class="size-4" /> Turn off
          </button>
        <% else %>
          <button type="button" phx-click="start_totp_enrolment" class={action_button_class()}>
            <.icon name="hero-shield-check" class="size-4" /> Set up two-factor authentication
          </button>
        <% end %>
      </:footer>
    </.section_card>
    """
  end

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
