defmodule QuantumBillingWeb.SettingsLive.ApiKeys do
  @moduledoc """
  Owner-only: the keys other systems use to reach the API.

  A key is access to the books without a person signing in, so issuing one is
  an owner's decision, as handing out accounts is. Both the route and the
  `on_mount` hook require an owner of the business being worked in, and the
  page shows and changes that business's keys only — a key issued here reaches
  this business's books and no other's.

  The key itself is shown once, straight after it is created, and never again:
  only its SHA-256 hash is stored, so there is nothing to show later. Lose it
  and the answer is to revoke it and issue another.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.ApiKeys
  alias QuantumBilling.ApiKeys.ApiKey

  @expiry_options [
    {"90 days", "90"},
    {"30 days", "30"},
    {"1 year", "365"},
    {"Never", "never"}
  ]

  @scope_descriptions %{
    "invoices:read" => "List and fetch invoices",
    "invoices:write" => "Create and cancel invoices",
    "invoices:payment_links" => "See each invoice's customer payment link",
    "invoices:payments" => "Record payments received outside the gateway",
    "invoices:e_invoice" => "Register invoices with the IRP for an IRN",
    "clients:read" => "List and fetch clients, including contact details",
    "clients:write" => "Create clients",
    "e_way_bills:read" => "List and fetch e-way bills",
    "credit_notes:read" => "List and fetch credit and debit notes",
    "credit_notes:write" => "Raise credit and debit notes against invoices"
  }

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "API keys")
     |> assign(:active_nav, :settings)
     |> assign(:new_key, nil)
     |> assign(:expiry_options, @expiry_options)
     |> assign(:scope_descriptions, @scope_descriptions)
     |> assign_form(%{"expires_in" => "90", "scopes" => ["invoices:read"]})
     |> load_keys()}
  end

  defp load_keys(socket),
    do: assign(socket, :keys, ApiKeys.list_keys(socket.assigns.current_scope.business))

  defp assign_form(socket, params, changeset \\ nil) do
    changeset =
      changeset || ApiKeys.change_key(%{"name" => params["name"], "scopes" => scopes(params)})

    socket
    |> assign(:form, to_form(changeset, as: :api_key))
    |> assign(:selected_scopes, scopes(params))
    |> assign(:expires_in, params["expires_in"] || "90")
  end

  def handle_event("validate", %{"api_key" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("create", %{"api_key" => params}, socket) do
    attrs = %{
      "name" => params["name"],
      "scopes" => scopes(params),
      "expires_at" => expires_at(params["expires_in"])
    }

    case ApiKeys.create_key(
           attrs,
           socket.assigns.current_scope.user,
           socket.assigns.current_scope.business
         ) do
      {:ok, %{key: key, raw: raw}} ->
        {:noreply,
         socket
         |> assign(:new_key, %{name: key.name, raw: raw})
         |> assign_form(%{"expires_in" => "90", "scopes" => ["invoices:read"]})
         |> load_keys()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, params, Map.put(changeset, :action, :insert))}
    end
  end

  # The raw key leaves the assigns as soon as the owner says they have it, so it
  # is not re-sent with every later render of this page.
  def handle_event("dismiss_new_key", _params, socket) do
    {:noreply, assign(socket, :new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case ApiKeys.get_key(socket.assigns.current_scope.business, id) do
      nil ->
        {:noreply, load_keys(socket)}

      key ->
        {:ok, _key} = ApiKeys.revoke_key(key, socket.assigns.current_scope.user)

        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{key.name} revoked. Requests made with it are refused from now on."
         )
         |> load_keys()}
    end
  end

  # The form sends an empty entry first so that unticking every box still
  # submits the field; it is not a scope.
  defp scopes(params), do: params |> Map.get("scopes") |> List.wrap() |> Enum.reject(&(&1 == ""))

  defp expires_at("never"), do: nil

  defp expires_at(days) do
    case Integer.parse(to_string(days)) do
      {days, ""} when days in [30, 90, 365] ->
        DateTime.utc_now(:second) |> DateTime.add(days * 86_400, :second)

      _other ->
        DateTime.utc_now(:second) |> DateTime.add(90 * 86_400, :second)
    end
  end

  defp state(%ApiKey{revoked_at: %DateTime{}}), do: "Revoked"

  defp state(%ApiKey{} = key) do
    if ApiKey.usable?(key), do: "Active", else: "Expired"
  end

  defp expiry(%ApiKey{expires_at: nil}), do: "Never"
  defp expiry(%ApiKey{expires_at: at}), do: format_date(DateTime.to_date(at))

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      active_sub={:"api-keys"}
    >
      <.header>
        API keys
        <:subtitle>
          Keys let your other systems read and create records through the API. Each
          key can do only what you tick, and every write it makes is in the audit log
          under its name.
        </:subtitle>
      </.header>

      <.card :if={@new_key} id="new-api-key" class="mb-4 border-success/40 bg-success/5">
        <div class="flex items-start gap-3">
          <.icon name="hero-key" class="mt-0.5 size-5 shrink-0 text-success" />
          <div class="min-w-0 flex-1">
            <h3 class="text-sm font-semibold">Copy the key for {@new_key.name} now</h3>
            <p class="mb-3 text-xs text-base-content/60">
              This is the only time it is shown. Only a fingerprint of it is stored, so it
              cannot be displayed again — if it is lost, revoke it and create another.
            </p>

            <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
              <code
                id="new-api-key-value"
                class="block min-w-0 flex-1 select-all break-all rounded-field border border-base-300 bg-base-100 px-3 py-2 font-mono text-xs"
              >
                {@new_key.raw}
              </code>

              <button
                id="copy-api-key"
                type="button"
                phx-hook=".CopyApiKey"
                data-target="new-api-key-value"
                class={secondary_button_class()}
              >
                <.icon name="hero-clipboard-document" class="size-4" />
                <span data-label>Copy</span>
              </button>

              <button
                id="dismiss-new-api-key"
                type="button"
                phx-click="dismiss_new_key"
                class={action_button_class()}
              >
                I have saved it
              </button>
            </div>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyApiKey">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const source = document.getElementById(this.el.dataset.target)
                const label = this.el.querySelector("[data-label]")
                if (!source || !navigator.clipboard) return
                navigator.clipboard.writeText(source.textContent.trim()).then(() => {
                  label.textContent = "Copied"
                  setTimeout(() => (label.textContent = "Copy"), 2000)
                })
              })
            }
          }
        </script>
      </.card>

      <.card class="mb-4">
        <h3 class="mb-1 text-sm font-semibold">Create a key</h3>
        <p class="mb-3 text-xs text-base-content/60">
          One key per system, named after it, with only the permissions it needs. Keys
          belong in that system's server configuration — never in a web page, a mobile
          app or a URL.
        </p>

        <.form for={@form} id="api-key-form" phx-change="validate" phx-submit="create">
          <div class="grid gap-3 sm:grid-cols-[1fr_12rem]">
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="e.g. Tally sync, Website checkout"
              maxlength="80"
              required
            />
            <.input
              name="api_key[expires_in]"
              id="api_key_expires_in"
              type="select"
              label="Expires after"
              options={@expiry_options}
              value={@expires_in}
            />
          </div>

          <fieldset id="api-key-scopes" class="mt-2">
            <legend class="mb-2 text-xs font-medium text-base-content/70">Permissions</legend>
            <input type="hidden" name="api_key[scopes][]" value="" />
            <div class="grid gap-2 sm:grid-cols-2">
              <label
                :for={scope <- ApiKey.scopes()}
                for={"scope-#{scope}"}
                class={[
                  "flex cursor-pointer items-start gap-2 rounded-field border px-3 py-2 transition-colors",
                  if(scope in @selected_scopes,
                    do: "border-primary/50 bg-primary/5",
                    else: "border-base-300 hover:border-base-content/30"
                  )
                ]}
              >
                <input
                  type="checkbox"
                  id={"scope-#{scope}"}
                  name="api_key[scopes][]"
                  value={scope}
                  checked={scope in @selected_scopes}
                  class="checkbox checkbox-sm mt-0.5"
                />
                <span class="min-w-0">
                  <span class="block font-mono text-xs">{scope}</span>
                  <span class="block text-xs text-base-content/60">
                    {@scope_descriptions[scope]}
                  </span>
                </span>
              </label>
            </div>
            <p
              :for={{message, _opts} <- Keyword.get_values(@form.errors, :scopes)}
              :if={@form.source.action}
              class="mt-1 text-xs text-error"
            >
              {message}
            </p>
          </fieldset>

          <div class="mt-4 flex justify-end">
            <button id="create-api-key" type="submit" class={action_button_class()}>
              <.icon name="hero-key" class="size-4" /> Create key
            </button>
          </div>
        </.form>
      </.card>

      <.card>
        <h3 class="mb-3 text-sm font-semibold">Keys</h3>

        <.empty_state
          :if={@keys == []}
          icon="hero-key"
          title="No API keys"
          description="Keys you create appear here, with when each was last used."
        />

        <div :if={@keys != []} class="overflow-x-auto">
          <table id="api-keys" class="table table-fixed">
            <thead>
              <tr class={table_head_class()}>
                <th class="w-48">Name</th>
                <th class="w-44">Key</th>
                <th>Permissions</th>
                <th class="w-32">Last used</th>
                <th class="w-28">Expires</th>
                <th class="w-24">State</th>
                <th class="w-24 text-right">Actions</th>
              </tr>
            </thead>

            <tbody>
              <tr :for={key <- @keys} id={"api-key-#{key.id}"} class={table_row_class()}>
                <td class="truncate">
                  {key.name}
                  <span :if={key.created_by} class="block truncate text-xs text-base-content/45">
                    by {key.created_by.email}
                  </span>
                </td>
                <td class="truncate font-mono text-xs">{key.prefix}…</td>
                <td>
                  <span
                    :for={scope <- key.scopes}
                    class="mb-0.5 mr-1 inline-block rounded-field bg-base-200 px-1.5 py-0.5 font-mono text-[11px]"
                  >
                    {scope}
                  </span>
                </td>
                <td class="text-xs text-base-content/60">
                  {relative_time(key.last_used_at)}
                  <span :if={key.last_used_ip} class="block truncate">{key.last_used_ip}</span>
                </td>
                <td class="text-xs text-base-content/60">{expiry(key)}</td>
                <td class="text-xs">{state(key)}</td>
                <td class="text-right">
                  <button
                    :if={is_nil(key.revoked_at)}
                    id={"revoke-api-key-#{key.id}"}
                    type="button"
                    phx-click="revoke"
                    phx-value-id={key.id}
                    data-confirm={"Revoke #{key.name}? Anything still using it will stop working immediately."}
                    class="btn btn-xs btn-ghost text-error"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
