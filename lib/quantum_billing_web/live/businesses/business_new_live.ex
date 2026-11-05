defmodule QuantumBillingWeb.BusinessNewLive do
  @moduledoc """
  Creates a business (name and optional GSTIN). Owners only; staff go back to the picker.

  On success a hidden form posts to the switch action (`phx-trigger-action`),
  since only an HTTP request can write the session.
  """
  use QuantumBillingWeb, :live_view

  alias QuantumBilling.Businesses

  @impl true
  def mount(_params, _session, socket) do
    if Businesses.owns_any?(socket.assigns.current_scope.user) do
      {:ok,
       socket
       |> assign(:page_title, "New business")
       |> assign(:active_nav, nil)
       |> assign(:created, nil)
       |> assign(:form, to_form(%{"name" => "", "gstin" => ""}, as: :business))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only an owner can add a business.")
       |> push_navigate(to: ~p"/businesses")}
    end
  end

  @impl true
  def handle_event("validate", %{"business" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :business))}
  end

  def handle_event("save", %{"business" => params}, socket) do
    case Businesses.create(socket.assigns.current_scope.user, params) do
      {:ok, business} ->
        {:noreply, assign(socket, :created, business)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(params, as: :business, errors: errors(changeset)))}
    end
  end

  # The name is checked on the business, the GSTIN on its settings; both land
  # on this one form. The settings call the name `company_name`.
  defp errors(changeset) do
    for {field, error} <- changeset.errors, field in [:name, :company_name, :gstin] do
      {if(field == :company_name, do: :name, else: field), error}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mx-auto w-full max-w-xl py-6">
        <.header>
          New business
          <:subtitle>
            A separate set of books: its own clients, invoices, numbering and settings.
          </:subtitle>
        </.header>

        <.card padding="p-5">
          <.form for={@form} id="business-form" phx-change="validate" phx-submit="save">
            <div class="space-y-4">
              <.field
                field={@form[:name]}
                label="Business name"
                required
                placeholder="Acme Traders Pvt Ltd"
                autocomplete="organization"
              />
              <.field
                field={@form[:gstin]}
                label="GSTIN"
                placeholder="27AABCA1234A1Z5"
                hint="Optional. You can add it later in Settings."
              />
            </div>

            <div class="mt-6 flex items-center justify-end gap-2">
              <.link navigate={~p"/businesses"} class={secondary_button_class()}>Cancel</.link>
              <button
                type="submit"
                id="create-business"
                disabled={@created != nil}
                phx-disable-with="Setting up…"
                class={action_button_class()}
              >
                <.icon name="hero-check" class="size-4" /> Create business
              </button>
            </div>
          </.form>
        </.card>

        <%!-- Submitted by LiveView once the business exists, to switch into it. --%>
        <.form
          :if={@created}
          for={%{}}
          id="switch-to-new-business"
          action={~p"/businesses/#{@created.id}/switch"}
          method="post"
          phx-trigger-action
        >
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
