defmodule QuantumBillingWeb.ClientShowLive do
  @moduledoc """
  One client: who they are, what they owe, and every invoice raised against
  them.

  ## Why this page exists

  The Clients list had an eye icon on every row that navigated to
  `/invoices?q=<name>` — the invoice list, filtered by a name search. An eye on
  a directory row means "open this record", the way it does on the Invoices
  list two pages over, so the icon promised a client and delivered a filtered
  list of something else. The row menu already carried a separate "View
  invoices" item doing exactly that, so the eye was both wrong and redundant.

  There was nowhere else for it to point: `/clients/:id/edit` was the only way
  into a client, which meant the only way to read one was to open it in a form
  and be careful not to save. That is what this page fixes.

  ## What it shows

  The stored record in full — identity, contact, both addresses, commercial
  terms, notes — and the invoice history underneath, paginated through
  `Invoices.page/1` with its `:client` option rather than a second query of its
  own. See `Invoices.page/1` on why that option matches an unlinked invoice by
  name: a client whose invoices were typed rather than picked would otherwise
  read as having none.

  The tiles across the top are deliberately derived from what is already
  loaded — the client row and the page's own `total` — so opening a client
  costs the two queries the page already makes and no aggregate on top.

  ## Live updates

  Subscribed to both topics. An edit in another window rewrites the record here
  (but only for *this* client), and an invoice written anywhere re-reads the
  history, because whether a new invoice belongs on this screen is a question
  about the filter rather than about the row.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.ClientsComponents

  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices

  @per_page 10

  # Redirect on a missing id: the link may be stale.
  def mount(%{"id" => id}, _session, socket) do
    case Clients.get_client(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That client no longer exists.")
         |> push_navigate(to: ~p"/clients")}

      client ->
        if connected?(socket) do
          Clients.subscribe()
          Invoices.subscribe()
        end

        {:ok,
         socket
         |> assign(:page_title, client.name)
         |> assign(:active_nav, :clients)
         |> assign(:client, client)
         |> assign(:page, 1)
         |> load_invoices()}
    end
  end

  def handle_event("paginate", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page, ""} -> {:noreply, socket |> assign(:page, page) |> load_invoices()}
      _not_a_page -> {:noreply, socket}
    end
  end

  def handle_event("set_status", %{"status" => status}, socket) do
    # Allowlisted: the status comes from the browser.
    if status in Clients.statuses() do
      case Clients.update_client(socket.assigns.client, %{"status" => status}) do
        {:ok, client} ->
          {:noreply,
           socket
           |> assign(:client, client)
           |> put_flash(:info, "#{client.name} is now #{String.downcase(status)}.")}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "That status could not be saved. Open the client and fix the highlighted fields."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  # Read fresh by id, and only an invoice shown on this page.
  def handle_event("delete_invoice", %{"id" => id}, socket) do
    with %{} = invoice <- Invoices.get_invoice(id),
         true <- Enum.any?(socket.assigns.invoices, &(&1.id == invoice.id)),
         {:ok, invoice} <-
           Invoices.delete_invoice(invoice, user_id: socket.assigns.current_scope.user.id) do
      {:noreply,
       socket
       |> put_flash(:info, "Invoice #{invoice.invoice_number} moved to the Bin.")
       |> load_invoices()}
    else
      nil ->
        {:noreply,
         socket |> put_flash(:error, "That invoice no longer exists.") |> load_invoices()}

      _refused ->
        {:noreply, put_flash(socket, :error, "That invoice could not be deleted.")}
    end
  end

  # Only this client's edits.
  def handle_info({event, client}, socket)
      when event in [:client_created, :client_updated, :client_restored] do
    if client.id == socket.assigns.client.id do
      {:noreply, assign(socket, :client, client)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({event, client}, socket) when event in [:client_binned, :client_purged] do
    if client.id == socket.assigns.client.id do
      {:noreply,
       socket
       |> put_flash(:info, "#{client.name} was moved to the Bin.")
       |> push_navigate(to: ~p"/clients")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:invoice_changed, _invoice}, socket) do
    {:noreply, load_invoices(socket)}
  end

  defp load_invoices(socket) do
    result =
      Invoices.page(
        client: socket.assigns.client,
        page: socket.assigns.page,
        per_page: @per_page
      )

    socket
    |> assign(:invoices, result.rows)
    |> assign(:invoice_count, result.total)
    |> assign(:total_pages, result.total_pages)
    |> assign(:page, result.page)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/45" aria-label="Breadcrumb">
        <.link navigate={~p"/clients"} class="hover:text-base-content">Clients</.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/60">{@client.name}</span>
      </nav>

      <.header>
        <%!-- A span: rendered inside the header's h1. --%>
        <span class="inline-flex items-center gap-3">
          <.client_avatar name={@client.name} />
          <span id="client-name">{@client.name}</span>
        </span>

        <:subtitle>
          {@client.client_type}
          <span :if={@client.display_name && @client.display_name != @client.name}>
            · also known as {@client.display_name}
          </span>
        </:subtitle>

        <:actions>
          <div class="flex flex-wrap items-center justify-end gap-2">
            <.status_badge status={@client.status} />

            <div class="dropdown dropdown-end">
              <div
                tabindex="0"
                role="button"
                class={secondary_button_class()}
                aria-label={"Change status for #{@client.name}"}
              >
                <.icon name="hero-arrow-path" class="size-4" /> Status
              </div>

              <ul
                tabindex="0"
                class="dropdown-content menu z-20 w-44 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-lg"
              >
                <li :for={status <- Clients.statuses()}>
                  <button
                    type="button"
                    phx-click="set_status"
                    phx-value-status={status}
                    disabled={@client.status == status}
                    class={@client.status == status && "text-base-content/45"}
                  >
                    <.icon
                      name={
                        if @client.status == status,
                          do: "hero-check-circle",
                          else: "hero-arrow-right-circle"
                      }
                      class="size-4"
                    /> {status}
                  </button>
                </li>
              </ul>
            </div>

            <.link
              id="client-invoices-link"
              navigate={~p"/invoices?q=#{@client.name}"}
              class={secondary_button_class()}
            >
              <.icon name="hero-document-text" class="size-4" /> All invoices
            </.link>

            <.link
              id="client-edit-link"
              navigate={~p"/clients/#{@client.id}/edit"}
              class={action_button_class()}
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit client
            </.link>
          </div>
        </:actions>
      </.header>

      <%!-- Each tile has an id so tests can target it. --%>
      <div id="client-summary" class="mt-2 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.summary_tile
          id="client-outstanding"
          label="Outstanding"
          value={rupees(@client.outstanding, decimals: 2, space: true)}
          hint="Unpaid balance carried on this account"
        />

        <.summary_tile
          id="client-invoice-count"
          label="Invoices"
          value={to_string(@invoice_count)}
          hint="Raised against this client"
        />

        <.summary_tile
          id="client-credit-limit"
          label="Credit limit"
          value={rupees(@client.credit_limit, decimals: 2, space: true)}
          hint="0 means no limit is enforced"
        />

        <.summary_tile
          id="client-payment-terms"
          label="Payment terms"
          value={"#{@client.payment_terms_days} days"}
          hint="Net days from the invoice date"
        />
      </div>

      <div class="mt-4 grid gap-3 lg:grid-cols-3">
        <.card id="client-identity" class="lg:col-span-1">
          <h2 class="text-sm font-semibold tracking-tight">Identity</h2>

          <dl class="mt-3 space-y-2.5">
            <.detail label="GSTIN" value={@client.gstin} mono />
            <.detail label="PAN" value={@client.pan} mono />
            <.detail label="Legal name" value={@client.legal_name} />
            <.detail label="Business type" value={@client.business_type} />
            <.detail label="Category" value={@client.category} />
          </dl>
        </.card>

        <.card id="client-contact" class="lg:col-span-1">
          <h2 class="text-sm font-semibold tracking-tight">Contact</h2>

          <dl class="mt-3 space-y-2.5">
            <.detail label="Email" value={@client.email} />
            <.detail label="Phone" value={phone(@client)} />
          </dl>

          <h2 class="mt-4 text-sm font-semibold tracking-tight">Commercial</h2>

          <dl class="mt-3 space-y-2.5">
            <.detail
              label="Opening balance"
              value={rupees(@client.opening_balance, decimals: 2, space: true)}
            />
            <.detail label="Added" value={format_date(DateTime.to_date(@client.inserted_at))} />
          </dl>
        </.card>

        <.card id="client-addresses" class="lg:col-span-1">
          <h2 class="text-sm font-semibold tracking-tight">Billing address</h2>

          <p class="mt-3 whitespace-pre-line text-sm text-base-content/70">
            {address_lines(@client, :billing)}
          </p>

          <h2 class="mt-4 text-sm font-semibold tracking-tight">Shipping address</h2>

          <%!-- Use the flag: when shipping follows billing the shipping fields are empty. --%>
          <p :if={@client.shipping_same_as_billing} class="mt-3 text-sm text-base-content/45">
            Same as the billing address.
          </p>

          <p
            :if={!@client.shipping_same_as_billing}
            class="mt-3 whitespace-pre-line text-sm text-base-content/70"
          >
            {address_lines(@client, :shipping)}
          </p>
        </.card>
      </div>

      <.card :if={@client.notes not in [nil, ""]} id="client-notes" class="mt-4">
        <h2 class="text-sm font-semibold tracking-tight">Notes</h2>
        <p class="mt-2 whitespace-pre-line text-sm text-base-content/70">{@client.notes}</p>
      </.card>

      <.card id="client-invoice-history" class="mt-4" padding="p-0">
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 p-4">
          <div>
            <h2 class="text-sm font-semibold tracking-tight">Invoice history</h2>
            <p class="mt-0.5 text-xs text-base-content/60">
              Every invoice raised against {@client.name}
            </p>
          </div>

          <.link navigate={~p"/invoices/new"} class={secondary_button_class()}>
            <.icon name="hero-plus" class="size-4" /> New invoice
          </.link>
        </div>

        <.empty_state
          :if={@invoices == []}
          icon="hero-document-text"
          title="No invoices for this client yet"
          description="Invoices raised against this client will be listed here."
        >
          <:action>
            <.link navigate={~p"/invoices/new"} class={action_button_class()}>
              Create New GST Invoice
            </.link>
          </:action>
        </.empty_state>

        <div :if={@invoices != []} class="overflow-x-auto">
          <table class="table">
            <thead class={table_head_class()}>
              <tr>
                <th>Invoice</th>
                <th>Date</th>
                <th>Due</th>
                <th>Amount</th>
                <th>Status</th>
                <th>Actions</th>
              </tr>
            </thead>

            <tbody>
              <tr
                :for={invoice <- @invoices}
                id={"client-invoice-#{invoice.id}"}
                class={table_row_class()}
              >
                <td class="font-medium">{invoice.number}</td>
                <td class="text-base-content/60">{format_date(invoice.invoice_date)}</td>
                <td class="text-base-content/60">{format_date(invoice.due_date)}</td>
                <td class="font-medium">{rupees(invoice.amount, decimals: 2, space: true)}</td>
                <td><.status_badge status={invoice.status} /></td>

                <td>
                  <div class="flex gap-1">
                    <.link
                      navigate={~p"/invoices/#{invoice.id}"}
                      class={row_action_class()}
                      aria-label={"Open invoice #{invoice.number}"}
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </.link>

                    <button
                      type="button"
                      id={"client-invoice-delete-#{invoice.id}"}
                      phx-click="delete_invoice"
                      phx-value-id={invoice.id}
                      data-confirm={"Move #{invoice.number} to the Bin? It can be restored from there."}
                      class={row_delete_class()}
                      aria-label={"Move invoice #{invoice.number} to the Bin"}
                      title="Move to Bin"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div
          :if={@total_pages > 1}
          class="flex items-center justify-between gap-3 border-t border-base-300 p-4"
        >
          <p class="text-xs text-base-content/60">
            {@invoice_count} invoices
          </p>

          <.pagination current_page={@page} total_pages={@total_pages} />
        </div>
      </.card>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  defp summary_tile(assigns) do
    ~H"""
    <.card id={@id}>
      <p class={micro_label_class()}>{@label}</p>
      <p class="mt-1.5 text-lg font-semibold tracking-tight">{@value}</p>
      <p :if={@hint} class="mt-0.5 text-xs text-base-content/45">{@hint}</p>
    </.card>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :mono, :boolean, default: false

  defp detail(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-3">
      <dt class="shrink-0 text-xs text-base-content/45">{@label}</dt>
      <dd class={[
        "text-right text-sm",
        @mono && "font-mono text-xs",
        blank?(@value) && "text-base-content/45"
      ]}>
        {if blank?(@value), do: "—", else: @value}
      </dd>
    </div>
    """
  end

  defp blank?(value), do: value in [nil, ""]

  defp phone(%{phone: phone}) when phone in [nil, ""], do: nil
  defp phone(%{phone_country_code: code, phone: phone}), do: "#{code} #{phone}"

  defp address_lines(client, prefix) do
    [:line1, :line2, :city, :state, :pin]
    |> Enum.map(&Map.get(client, :"#{prefix}_#{&1}"))
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "No address on file."
      parts -> Enum.join(parts, "\n")
    end
  end
end
