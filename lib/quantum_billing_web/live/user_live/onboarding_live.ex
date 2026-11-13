defmodule QuantumBillingWeb.OnboardingLive do
  @moduledoc """
  First sign-in onboarding: welcome, about you, your organisation, finish.

  Shown once to every account, prefilled and skippable. `UserAuth` redirects
  here until `Accounts.complete_onboarding/1` sets `onboarded_at`. Owners edit
  the current (or only) business; staff see it read-only.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.Illustrations,
    only: [welcome: 1, profile: 1, organization: 1, success: 1]

  alias QuantumBilling.Accounts
  alias QuantumBilling.Businesses
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  @steps 4

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    {business, role} = organisation_business(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Set up your account")
     |> assign(:step, 1)
     |> assign(:steps, @steps)
     |> assign(:business, business)
     |> assign(:owner?, role == "owner")
     |> assign(:profile_form, to_form(Accounts.change_onboarding(user), as: :profile))
     |> assign_organization()}
  end

  # The scope's business, else the one business the user belongs to, else none.
  defp organisation_business(%{business: %{} = business, membership: membership}) do
    {business, membership && membership.role}
  end

  defp organisation_business(%{user: user}) do
    case Businesses.list_for_user(user) do
      [{business, membership}] -> {business, membership.role}
      _none_or_several -> {nil, nil}
    end
  end

  defp assign_organization(%{assigns: %{business: nil}} = socket) do
    assign(socket, organization: nil, org_form: nil)
  end

  defp assign_organization(%{assigns: %{business: business}} = socket) do
    organization = Repo.with_business(business, &Settings.get_organization/0)

    # Prefilled with the company's own name until its settings carry one.
    params =
      if organization.company_name in [nil, ""],
        do: %{"company_name" => business.name},
        else: %{}

    socket
    |> assign(:organization, organization)
    |> assign(:org_form, org_form(organization, params))
  end

  defp org_form(organization, params, action \\ nil) do
    organization
    |> Settings.change_organization(params, :general)
    |> to_form(as: :organization, action: action)
  end

  @impl true
  def handle_event("next", _params, socket), do: {:noreply, go(socket, socket.assigns.step + 1)}

  def handle_event("back", _params, socket), do: {:noreply, go(socket, socket.assigns.step - 1)}

  def handle_event("validate_profile", %{"profile" => params}, socket) do
    changeset = Accounts.change_onboarding(socket.assigns.current_scope.user, params)
    {:noreply, assign(socket, :profile_form, to_form(changeset, as: :profile, action: :validate))}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    case Accounts.save_onboarding_profile(socket.assigns.current_scope.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_user(user)
         |> assign(:profile_form, to_form(Accounts.change_onboarding(user), as: :profile))
         |> go(3)}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: :profile))}
    end
  end

  def handle_event("validate_org", %{"organization" => params}, socket) do
    if socket.assigns.owner? and socket.assigns.organization do
      {:noreply,
       assign(socket, :org_form, org_form(socket.assigns.organization, params, :validate))}
    else
      {:noreply, socket}
    end
  end

  # Owners only, checked here and again by Businesses.rename/3: the role in
  # the socket decides what is drawn, never what is allowed.
  def handle_event("save_org", %{"organization" => params}, %{assigns: %{owner?: true}} = socket) do
    %{business: business, organization: organization} = socket.assigns
    user = socket.assigns.current_scope.user
    params = Map.take(params, ~w(company_name email phone gstin state))

    result =
      Repo.with_business(business, fn ->
        Settings.update_section(organization, params, :general)
      end)

    case result do
      {:ok, saved} ->
        socket =
          case rename_business(user, business, saved.company_name) do
            {:ok, renamed} -> assign(socket, :business, renamed)
            _unchanged_or_refused -> socket
          end

        {:noreply,
         socket
         |> assign(:organization, saved)
         |> assign(:org_form, org_form(saved, %{}))
         |> go(4)}

      {:error, changeset} ->
        {:noreply, assign(socket, :org_form, to_form(changeset, as: :organization))}
    end
  end

  def handle_event("save_org", _params, socket), do: {:noreply, go(socket, 4)}

  def handle_event("finish", _params, socket), do: {:noreply, complete(socket, "You're all set.")}

  def handle_event("skip", _params, socket) do
    {:noreply,
     complete(
       socket,
       "Skipped for now. Your profile is in Account settings whenever you want it."
     )}
  end

  defp rename_business(_user, %{name: name}, name), do: :unchanged
  defp rename_business(_user, _business, blank) when blank in [nil, ""], do: :unchanged

  defp rename_business(user, business, name) do
    Businesses.rename(user, business, %{"name" => name})
  end

  defp complete(socket, message) do
    {:ok, user} = Accounts.complete_onboarding(socket.assigns.current_scope.user)

    socket
    |> put_user(user)
    |> put_flash(:info, message)
    |> push_navigate(to: ~p"/")
  end

  defp put_user(socket, user) do
    assign(socket, :current_scope, %{socket.assigns.current_scope | user: user})
  end

  defp go(socket, step), do: assign(socket, :step, step |> max(1) |> min(@steps))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.focus flash={@flash} current_scope={@current_scope} step={@step} steps={@steps}>
      <div id="onboarding" class="flex w-full max-w-5xl flex-1 flex-col">
        <div
          id={"onboarding-step-#{@step}"}
          class="qb-rise my-auto grid w-full grid-cols-1 items-center gap-8 lg:grid-cols-[1fr_1.15fr] lg:gap-14"
        >
          <div class="flex justify-center lg:order-2">
            <div class="relative flex w-full max-w-sm items-center justify-center">
              <%= case @step do %>
                <% 1 -> %>
                  <.welcome class="h-52 w-auto sm:h-64" />
                <% 2 -> %>
                  <.profile class="h-52 w-auto sm:h-64" />
                <% 3 -> %>
                  <.organization class="h-52 w-auto sm:h-64" />
                <% _ -> %>
                  <.success class="qb-pop-in h-52 w-auto sm:h-64" />
              <% end %>
            </div>
          </div>

          <div class="lg:order-1">
            {render_step(assigns)}
          </div>
        </div>
      </div>

      <:footer>
        <div class="flex items-center gap-2">
          <button
            :if={@step > 1 and @step < @steps}
            type="button"
            id="onboarding-back"
            phx-click="back"
            class={Layouts.focus_back_class()}
          >
            <.icon name="hero-arrow-left-mini" class="size-4" /> Back
          </button>
          <button
            :if={@step < @steps}
            type="button"
            id="onboarding-skip"
            phx-click="skip"
            class="rounded-full px-3 py-2 text-sm text-base-content/55 transition-colors hover:text-base-content"
          >
            Skip for now
          </button>
        </div>

        <%= case @step do %>
          <% 1 -> %>
            <button
              type="button"
              id="onboarding-next"
              phx-click="next"
              class={Layouts.focus_next_class()}
            >
              Let's go <.icon name="hero-arrow-right-mini" class="size-4" />
            </button>
          <% 2 -> %>
            <button
              type="submit"
              form="onboarding-profile-form"
              id="onboarding-next"
              phx-disable-with="Saving…"
              class={Layouts.focus_next_class()}
            >
              Next <.icon name="hero-arrow-right-mini" class="size-4" />
            </button>
          <% 3 -> %>
            <%= if @owner? and @org_form do %>
              <button
                type="submit"
                form="onboarding-org-form"
                id="onboarding-next"
                phx-disable-with="Saving…"
                class={Layouts.focus_next_class()}
              >
                Next <.icon name="hero-arrow-right-mini" class="size-4" />
              </button>
            <% else %>
              <button
                type="button"
                id="onboarding-next"
                phx-click="next"
                class={Layouts.focus_next_class()}
              >
                Next <.icon name="hero-arrow-right-mini" class="size-4" />
              </button>
            <% end %>
          <% _ -> %>
            <button
              type="button"
              id="onboarding-finish"
              phx-click="finish"
              class={Layouts.focus_next_class()}
            >
              Go to my workspace <.icon name="hero-arrow-right-mini" class="size-4" />
            </button>
        <% end %>
      </:footer>
    </Layouts.focus>
    """
  end

  defp render_step(%{step: 1} = assigns) do
    ~H"""
    <p class="text-sm font-medium text-base-content/55">Welcome to QuantumBilling</p>
    <h1 class="mt-1.5 text-3xl font-semibold tracking-tight sm:text-4xl">
      Hi{first_name(@current_scope.user)}! Let's set up your account.
    </h1>
    <p class="mt-3 max-w-md text-base text-base-content/65">
      Two quick steps, about a minute. You can change all of it later.
    </p>
    <ol class="mt-7 flex max-w-md flex-col gap-3">
      <.plan_item icon="hero-user-circle" title="About you">
        Your name, job title, phone and a short bio
      </.plan_item>
      <.plan_item icon="hero-building-office-2" title="Your organisation">
        Its name, contact details and GSTIN
      </.plan_item>
      <.plan_item icon="hero-rocket-launch" title="Start billing">
        Straight into your workspace
      </.plan_item>
    </ol>
    """
  end

  defp render_step(%{step: 2} = assigns) do
    ~H"""
    <p class="text-sm font-medium text-base-content/55">Step 1 of 2</p>
    <h1 class="mt-1.5 text-2xl font-semibold tracking-tight sm:text-3xl">About you</h1>
    <p class="mt-2 text-sm text-base-content/60">
      Shown to your team and on the documents you prepare.
    </p>

    <.form
      for={@profile_form}
      id="onboarding-profile-form"
      phx-change="validate_profile"
      phx-submit="save_profile"
      class="mt-6 grid max-w-xl grid-cols-1 gap-x-4 sm:grid-cols-2"
    >
      <div class="sm:col-span-2">
        <.input
          field={@profile_form[:full_name]}
          type="text"
          label="Full name"
          placeholder="Priya Sharma"
          autocomplete="name"
          phx-mounted={JS.focus()}
        />
      </div>
      <.input
        field={@profile_form[:designation]}
        type="text"
        label="Job title"
        placeholder="Accounts manager"
        autocomplete="organization-title"
      />
      <.input
        field={@profile_form[:phone]}
        type="tel"
        label="Phone"
        placeholder="+91 98765 43210"
        autocomplete="tel"
      />
      <div class="sm:col-span-2">
        <.input
          field={@profile_form[:bio]}
          type="textarea"
          label="Bio"
          rows="3"
          placeholder="A line or two about what you do"
        />
      </div>
    </.form>

    <div
      id="onboarding-email"
      class="mt-1 flex max-w-xl items-center gap-3 rounded-2xl border border-base-content/10 bg-base-100/70 px-4 py-3"
    >
      <span class="flex size-9 shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/60">
        <.icon name="hero-envelope" class="size-4.5" />
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-xs text-base-content/50">Sign-in email</p>
        <p class="truncate text-sm font-medium">{@current_scope.user.email}</p>
      </div>
      <.link
        navigate={~p"/users/settings"}
        class="shrink-0 text-xs font-medium text-base-content underline-offset-2 hover:underline"
      >
        Change
      </.link>
    </div>
    """
  end

  defp render_step(%{step: 3} = assigns) do
    ~H"""
    <p class="text-sm font-medium text-base-content/55">Step 2 of 2</p>
    <h1 class="mt-1.5 text-2xl font-semibold tracking-tight sm:text-3xl">Your organisation</h1>

    <%= cond do %>
      <% is_nil(@business) -> %>
        <p id="onboarding-org-none" class="mt-3 max-w-md text-sm text-base-content/65">
          You belong to more than one company. Choose one after this, and fill in its details
          under Settings › General.
        </p>
      <% @owner? -> %>
        <p class="mt-2 text-sm text-base-content/60">
          These appear on every invoice. The rest lives in Settings › General.
        </p>
        <.form
          for={@org_form}
          id="onboarding-org-form"
          phx-change="validate_org"
          phx-submit="save_org"
          class="mt-6 grid max-w-xl grid-cols-1 gap-x-4 sm:grid-cols-2"
        >
          <div class="sm:col-span-2">
            <.input
              field={@org_form[:company_name]}
              type="text"
              label="Organisation name"
              placeholder="Acme Traders Private Limited"
              autocomplete="organization"
              phx-mounted={JS.focus()}
            />
          </div>
          <.input
            field={@org_form[:email]}
            type="email"
            label="Business email"
            placeholder="accounts@acme.in"
          />
          <.input
            field={@org_form[:phone]}
            type="tel"
            label="Business phone"
            placeholder="+91 22 4000 1234"
          />
          <.input
            field={@org_form[:gstin]}
            type="text"
            label="GSTIN"
            placeholder="27AABCA1234A1Z5"
            class="w-full input font-mono uppercase"
          />
          <.input
            field={@org_form[:state]}
            type="select"
            label="State"
            prompt="Select state"
            options={EWayBillForm.states()}
          />
        </.form>
      <% true -> %>
        <p class="mt-2 text-sm text-base-content/60">
          You are on the staff of this company. Its owners keep these details up to date.
        </p>
        <dl
          id="onboarding-org-readonly"
          class="mt-6 grid max-w-xl grid-cols-1 gap-px overflow-hidden rounded-2xl border border-base-content/10 bg-base-content/10 sm:grid-cols-2"
        >
          <.org_fact label="Organisation">
            {blank(@organization.company_name, @business.name)}
          </.org_fact>
          <.org_fact label="GSTIN">{blank(@organization.gstin)}</.org_fact>
          <.org_fact label="Email">{blank(@organization.email)}</.org_fact>
          <.org_fact label="Phone">{blank(@organization.phone)}</.org_fact>
        </dl>
    <% end %>
    """
  end

  defp render_step(assigns) do
    ~H"""
    <p class="text-sm font-medium text-base-content/55">All done</p>
    <h1 id="onboarding-done" class="mt-1.5 text-3xl font-semibold tracking-tight sm:text-4xl">
      You're all set{first_name(@current_scope.user)}!
    </h1>
    <p class="mt-3 max-w-md text-base text-base-content/65">
      Your account is ready. Create your first invoice, add a client, or make the invoice
      design your own in Settings › Customization.
    </p>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp plan_item(assigns) do
    ~H"""
    <li class="flex items-center gap-3 rounded-2xl border border-base-content/10 bg-base-100/70 p-3">
      <span class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-base-200 text-base-content/70">
        <.icon name={@icon} class="size-5" />
      </span>
      <span class="min-w-0">
        <span class="block text-sm font-semibold">{@title}</span>
        <span class="block text-xs text-base-content/55">{render_slot(@inner_block)}</span>
      </span>
    </li>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp org_fact(assigns) do
    ~H"""
    <div class="bg-base-100 px-4 py-3">
      <dt class="text-xs text-base-content/50">{@label}</dt>
      <dd class="mt-0.5 truncate text-sm font-medium">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp first_name(%{full_name: name}) when is_binary(name) and name != "" do
    ", " <> (name |> String.split(~r/\s+/, trim: true) |> List.first())
  end

  defp first_name(_user), do: ""

  defp blank(value, fallback \\ "—")
  defp blank(value, fallback) when value in [nil, ""], do: fallback
  defp blank(value, _fallback), do: value
end
