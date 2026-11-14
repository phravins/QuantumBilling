defmodule QuantumBillingWeb.InvoiceTemplateDesignLive do
  @moduledoc """
  The invoice design pad: block palette, canvas and inspector.

  The layout is parsed on mount and kept in memory; every change autosaves.
  Events address blocks by server ids, and unknown ids are ignored. Images are
  inlined as data URIs, since `/uploads` requests can hit an expired session.
  The Logo section sets the organisation's logo, shared by every design.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.InvoiceTemplateComponents

  alias QuantumBilling.DesignAssets
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBilling.Uploads
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Extras
  alias QuantumBillingWeb.InvoiceDoc.Layout
  alias QuantumBillingWeb.InvoiceDoc.Renderer
  alias QuantumBillingWeb.InvoiceDocument
  alias QuantumBillingWeb.InvoicePdfGenerator

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Templates.get_template(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That template does not exist.")
         |> push_navigate(to: ~p"/settings/customization")}

      template ->
        organization = Settings.get_organization()

        {:ok,
         socket
         |> assign(:page_title, template.name)
         |> assign(:active_nav, :settings)
         |> assign(:active_sub, :customization)
         |> assign(:template, template)
         |> assign(:organization, organization)
         |> assign(:selected_id, nil)
         |> assign(:saved_at, nil)
         |> assign(:error, nil)
         |> assign(:upload_error, nil)
         |> assign(:logo_error, nil)
         |> assign(:sample, InvoiceDocument.pad_sample(organization))
         |> assign_logo()
         |> put_doc(Templates.document_of(template))
         |> assign(:form, to_form(%{"name" => template.name, "accent" => template.accent}))
         |> allow_upload(:background, upload_opts(:background))
         |> allow_upload(:image, upload_opts(:image))
         |> allow_upload(:logo, upload_opts(:logo))}
    end
  end

  @impl true
  def handle_event("add_block", %{"type" => type}, socket) do
    doc = socket.assigns.doc

    case block_type(type) do
      nil ->
        {:noreply, socket}

      type ->
        if Catalog.singleton?(type) and Document.has_type?(doc, type) do
          {:noreply, socket}
        else
          block = Catalog.new(type, Document.next_id(doc))
          doc = %{doc | blocks: doc.blocks ++ [block]}

          {:noreply, socket |> assign(:selected_id, block.id) |> save(doc)}
        end
    end
  end

  def handle_event("remove_block", %{"id" => id}, socket) do
    doc = socket.assigns.doc

    case Document.block(doc, id) do
      nil ->
        {:noreply, socket}

      block ->
        if Catalog.required?(block.type) do
          {:noreply,
           put_flash(
             socket,
             :error,
             "An invoice needs its #{label_for(block.type)}, so that block cannot be removed."
           )}
        else
          doc = %{doc | blocks: Enum.reject(doc.blocks, &(&1.id == id))}

          selected =
            if socket.assigns.selected_id == id, do: nil, else: socket.assigns.selected_id

          {:noreply, socket |> assign(:selected_id, selected) |> save(doc)}
        end
    end
  end

  def handle_event("move_block", %{"id" => id, "dir" => dir}, socket) do
    doc = socket.assigns.doc
    ids = Document.ids(doc)
    index = Enum.find_index(ids, &(&1 == id))

    case swap(ids, index, dir) do
      nil -> {:noreply, socket}
      reordered -> {:noreply, save(socket, reorder(doc, reordered))}
    end
  end

  @doc """
  Reorders from the drag hook. Accepted only if it is an exact permutation of the current ids.
  """
  def handle_event("reorder_blocks", %{"ids" => ids}, socket) when is_list(ids) do
    current = Document.ids(socket.assigns.doc)

    if Enum.sort(ids) == Enum.sort(current) do
      {:noreply, save(socket, reorder(socket.assigns.doc, ids))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, id)}
  end

  def handle_event("update_block", %{"_id" => id} = params, socket) do
    doc = socket.assigns.doc

    case Document.block(doc, id) do
      nil ->
        {:noreply, socket}

      block ->
        # Through the catalogue's allowlist, never straight onto the struct.
        {:noreply, save(socket, Document.put_block(doc, Catalog.cast_block(block, params)))}
    end
  end

  def handle_event("toggle_child", %{"field" => field}, socket) do
    with_selected(socket, fn doc, block ->
      cond do
        Enum.any?(block.children, &(&1.field == field)) ->
          if block.type == :items and Catalog.required_item_field?(field) do
            :error
          else
            children = Enum.reject(block.children, &(&1.field == field))
            {:ok, Document.put_block(doc, %{block | children: children})}
          end

        child = Catalog.new_child(block.type, field) ->
          {:ok, Document.put_block(doc, %{block | children: block.children ++ [child]})}

        true ->
          :error
      end
    end)
  end

  def handle_event("move_child", %{"field" => field, "dir" => dir}, socket) do
    with_selected(socket, fn doc, block ->
      fields = Enum.map(block.children, & &1.field)
      index = Enum.find_index(fields, &(&1 == field))

      case swap(fields, index, dir) do
        nil ->
          :error

        reordered ->
          children = Enum.map(reordered, fn f -> Enum.find(block.children, &(&1.field == f)) end)
          {:ok, Document.put_block(doc, %{block | children: children})}
      end
    end)
  end

  # The form exists only for the file input.
  def handle_event("validate_upload", _params, socket) do
    {:noreply, assign(socket, :upload_error, upload_error(socket))}
  end

  def handle_event("remove_background", _params, socket) do
    doc = socket.assigns.doc
    {:noreply, save(socket, Layout.put_background(doc, ""))}
  end

  def handle_event("validate_logo", _params, socket) do
    {:noreply, assign(socket, :logo_error, logo_upload_error(socket))}
  end

  def handle_event("remove_logo", _params, socket) do
    {:noreply, put_logo(socket, nil)}
  end

  # For a logo uploaded as a letterhead: it becomes the logo and leaves the page.
  def handle_event("use_background_as_logo", _params, socket) do
    path = socket.assigns.doc.page.background

    if path != "" and DesignAssets.owned?(path) do
      socket = put_logo(socket, path)

      if socket.assigns.logo_error do
        {:noreply, socket}
      else
        {:noreply, save(socket, Layout.put_background(socket.assigns.doc, ""))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_image", _params, socket) do
    with_selected(socket, fn doc, block ->
      if block.type == :image do
        {:ok, Document.put_block(doc, %{block | opts: Map.put(block.opts, :path, "")})}
      else
        :error
      end
    end)
  end

  def handle_event("update_page", %{"page" => params}, socket) do
    doc = socket.assigns.doc

    {:noreply, save(socket, %{doc | page: Layout.cast_page(doc.page, params)})}
  end

  def handle_event("reset_text", _params, socket) do
    doc = socket.assigns.doc

    {:noreply, save(socket, %{doc | page: Layout.default_page()})}
  end

  def handle_event("update_template", params, socket) do
    attrs = Map.take(params, ["name", "accent"])

    case Templates.update_template(socket.assigns.template, attrs) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:template, template)
         |> assign(:page_title, template.name)
         |> assign(:error, nil)
         |> mark_saved()}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, first_error(changeset))}
    end
  end

  def handle_event("set_default", _params, socket) do
    case Templates.set_default(socket.assigns.template) do
      {:ok, template} ->
        {:noreply, socket |> assign(:template, template) |> mark_saved()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That could not be made default.")}
    end
  end

  def handle_event("reset_layout", _params, socket) do
    {:noreply, socket |> assign(:selected_id, nil) |> save(Catalog.classic())}
  end

  # A letterhead must be PNG or JPEG; a stamp or logo may be anything `Uploads.store/2` takes.
  defp upload_opts(name) do
    [
      accept: accepted(name),
      max_entries: 1,
      max_file_size: Uploads.max_bytes(),
      auto_upload: true,
      progress: &handle_progress/3
    ]
  end

  defp accepted(:background), do: ~w(.png .jpg .jpeg)
  defp accepted(:image), do: ~w(.png .jpg .jpeg .webp)
  defp accepted(:logo), do: ~w(.png .jpg .jpeg .gif .webp)

  defp handle_progress(:logo, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Uploads.store(path, entry.client_type)}
        end)

      case result do
        {:ok, stored} -> {:noreply, put_logo(socket, stored)}
        {:error, message} -> {:noreply, assign(socket, :logo_error, "That logo #{message}.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_progress(name, entry, socket) when name in [:background, :image] do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Uploads.store(path, entry.client_type)}
        end)

      case result do
        {:ok, stored} ->
          kind = if name == :background, do: "background", else: "image"
          :ok = DesignAssets.record(stored, kind)
          {:noreply, socket |> assign(:upload_error, nil) |> place_upload(name, stored)}

        {:error, message} ->
          {:noreply, assign(socket, :upload_error, "That image #{message}.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp place_upload(socket, :background, path) do
    save(socket, Layout.put_background(socket.assigns.doc, path))
  end

  defp place_upload(socket, :image, path) do
    doc = socket.assigns.doc

    case Document.block(doc, socket.assigns.selected_id) do
      %{type: :image} = block ->
        save(socket, Document.put_block(doc, %{block | opts: Map.put(block.opts, :path, path)}))

      _not_an_image ->
        socket
    end
  end

  # Sets or clears the organisation's logo, adding a logo block at the top if there is none.
  defp put_logo(socket, path) do
    organization = socket.assigns.organization
    previous = organization.doc_logo_path

    case Settings.update_section(organization, %{"doc_logo_path" => path}, :customization) do
      {:ok, organization} ->
        # Unlinked only after the new one is saved, and never while a design still uses the file.
        if is_binary(previous) and previous != path and not DesignAssets.recorded?(previous) do
          Uploads.delete(previous)
        end

        socket
        |> assign(:organization, organization)
        |> assign(:logo_error, nil)
        |> assign_logo()
        |> ensure_logo_block(path)

      {:error, _changeset} ->
        assign(socket, :logo_error, "That logo could not be saved.")
    end
  end

  defp ensure_logo_block(socket, nil), do: socket

  defp ensure_logo_block(socket, _path) do
    doc = socket.assigns.doc

    if Document.has_type?(doc, :logo) do
      socket
    else
      save(socket, %{doc | blocks: [Catalog.new(:logo, Document.next_id(doc)) | doc.blocks]})
    end
  end

  defp assign_logo(socket) do
    path = presence(socket.assigns.organization.doc_logo_path)

    socket
    |> assign(:logo_path, path)
    |> assign(:logo, path && InvoicePdfGenerator.inline_logo(path))
  end

  defp logo_upload_error(socket) do
    upload = socket.assigns.uploads.logo

    case upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1)) do
      [:too_large | _] -> "That logo is larger than #{div(Uploads.max_bytes(), 1_000_000)}MB."
      [:not_accepted | _] -> "The logo has to be a PNG, JPEG, GIF or WebP image."
      [:too_many_files | _] -> "One logo at a time."
      [_other | _] -> "That logo could not be uploaded."
      [] -> nil
    end
  end

  defp upload_error(socket) do
    errors =
      Enum.flat_map([:background, :image], fn name ->
        upload = socket.assigns.uploads[name]
        upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1))
      end)

    case errors do
      [:too_large | _] -> "That image is larger than #{div(Uploads.max_bytes(), 1_000_000)}MB."
      [:not_accepted | _] -> "That has to be a PNG or JPEG image."
      [:too_many_files | _] -> "One image at a time."
      [_other | _] -> "That image could not be uploaded."
      [] -> nil
    end
  end

  # The document and what its newer blocks render with travel together.
  defp put_doc(socket, doc) do
    extras = Extras.build(socket.assigns.sample, doc, organization: socket.assigns.organization)

    socket
    |> assign(:doc, doc)
    |> assign(:extras, inline_images(extras, socket.assigns[:extras]))
  end

  # Extras.build has already dropped paths this business doesn't own; files in use aren't re-read.
  defp inline_images(%{images: images} = extras, previous) when map_size(images) > 0 do
    cache = (previous && previous.images) || %{}

    %{
      extras
      | images:
          Map.new(images, fn {path, src} ->
            {path, Map.get(cache, path) || InvoicePdfGenerator.inline_logo(src)}
          end)
    }
  end

  defp inline_images(extras, _previous), do: extras

  # A rejected save keeps the user's change on the canvas and shows why.
  defp save(socket, doc) do
    socket = put_doc(socket, doc)

    case Templates.update_template(socket.assigns.template, %{"layout_xml" => Layout.to_xml(doc)}) do
      {:ok, template} ->
        socket |> assign(:template, template) |> assign(:error, nil) |> mark_saved()

      {:error, changeset} ->
        assign(socket, :error, first_error(changeset))
    end
  end

  defp mark_saved(socket), do: assign(socket, :saved_at, Time.utc_now())

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {_field, messages} -> List.wrap(messages) end)
    |> List.first()
  end

  defp with_selected(socket, fun) do
    doc = socket.assigns.doc

    case Document.block(doc, socket.assigns.selected_id) do
      nil ->
        {:noreply, socket}

      block ->
        case fun.(doc, block) do
          {:ok, doc} -> {:noreply, save(socket, doc)}
          :error -> {:noreply, socket}
        end
    end
  end

  defp reorder(doc, ids) do
    %{doc | blocks: Enum.map(ids, fn id -> Document.block(doc, id) end)}
  end

  defp swap(_list, nil, _dir), do: nil
  defp swap(_list, 0, "up"), do: nil

  defp swap(list, index, "up") do
    List.replace_at(list, index, Enum.at(list, index - 1))
    |> List.replace_at(index - 1, Enum.at(list, index))
  end

  defp swap(list, index, "down") when index >= 0 do
    if index == length(list) - 1 do
      nil
    else
      List.replace_at(list, index, Enum.at(list, index + 1))
      |> List.replace_at(index + 1, Enum.at(list, index))
    end
  end

  defp swap(_list, _index, _dir), do: nil

  # Never `String.to_atom/1` on a param. The palette is a closed list.
  defp block_type(value) do
    Enum.find(Catalog.types(), fn type -> to_string(type) == value end)
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:selected, Document.block(assigns.doc, assigns.selected_id))
      |> assign(:count, length(assigns.doc.blocks))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_nav={@active_nav}
      active_sub={@active_sub}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <nav class="mb-2 flex items-center gap-1.5 text-xs text-base-content/45" aria-label="Breadcrumb">
        <.link navigate={~p"/settings/customization"} class="hover:text-base-content">
          Invoice Customization
        </.link>
        <.icon name="hero-chevron-right" class="size-3" />
        <span class="text-base-content/60">{@template.name}</span>
      </nav>

      <.header>
        <form
          id="template-name-form"
          phx-change="update_template"
          phx-submit="update_template"
          class="contents"
        >
          <input
            type="text"
            name="name"
            value={@template.name}
            aria-label="Template name"
            class="w-full max-w-sm rounded-field border border-transparent bg-transparent px-1 py-0.5 text-xl font-semibold tracking-tight hover:border-base-300 focus:border-(--qb-field-focus) focus:outline-none"
          />
        </form>

        <:subtitle>
          <span :if={@error} class="text-red-600 dark:text-red-400">{@error}</span>
          <span :if={is_nil(@error) and @saved_at} class="text-base-content/45">Saved</span>
          <span :if={is_nil(@error) and is_nil(@saved_at)}>
            {@count} blocks · changes save as you make them
          </span>
        </:subtitle>

        <:actions>
          <div class="flex items-center gap-2">
            <form
              id="template-accent-form"
              phx-change="update_template"
              class="flex items-center gap-1.5"
            >
              <label for="template-accent" class="text-xs text-base-content/60">Accent</label>
              <input
                type="color"
                id="template-accent"
                name="accent"
                value={@template.accent}
                class="size-8 cursor-pointer rounded-field border border-base-300 bg-base-100 p-0.5"
              />
            </form>

            <button
              :if={!@template.is_default}
              type="button"
              phx-click="set_default"
              class={secondary_button_class()}
            >
              Make default
            </button>

            <span
              :if={@template.is_default}
              class="inline-flex h-9 items-center rounded-field bg-base-200 px-3 text-sm text-base-content/70"
            >
              Default
            </span>

            <.link navigate={~p"/settings/customization"} class={secondary_button_class()}>
              Done
            </.link>
          </div>
        </:actions>
      </.header>

      <.text_tools id="template-page-form" page={@doc.page} class="mb-2" />

      <div class="flex flex-1 gap-3">
        <.card padding="p-2" class="hidden w-44 shrink-0 self-start lg:block">
          <.block_palette doc={@doc} />
          <div class="mt-3 space-y-2 border-t border-base-300 pt-3">
            <button
              type="button"
              phx-click="reset_layout"
              data-confirm="Reset this template to the standard layout? Your changes to it will be lost."
              class="w-full rounded-field px-1 py-1 text-left text-xs text-base-content/45 hover:text-red-600 dark:hover:text-red-400"
            >
              Reset to standard
            </button>
          </div>
        </.card>
        <.card padding="p-6" class="min-w-0 flex-1">
          <Renderer.stylesheet doc={@doc} />
          <%!-- The hook pushes the new id order; no phx-update="ignore", since the server re-render moves blocks. --%>
          <div id="canvas-blocks" phx-hook=".BlockSort" class="mx-auto max-w-[800px] space-y-1">
            <.canvas_block
              :for={{block, index} <- Enum.with_index(@doc.blocks)}
              block={block}
              doc={@doc}
              invoice={@sample}
              logo={@logo}
              extras={@extras}
              accent={@template.accent}
              selected={block.id == @selected_id}
              first={index == 0}
              last={index == @count - 1}
            />
          </div>

          <p :if={@count == 0} class="py-10 text-center text-sm text-base-content/45">
            This template is empty. Add a block from the left to begin.
          </p>
        </.card>
        <.card padding="p-3" class="hidden w-72 shrink-0 self-start xl:block">
          <.inspector block={@selected} page={@doc.page} uploads={@uploads} extras={@extras} />
          <.page_panel
            page={@doc.page}
            uploads={@uploads}
            extras={@extras}
            upload_error={@upload_error}
            logo={@logo}
            logo_error={@logo_error}
          />
        </.card>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BlockSort">
        // Reorders canvas blocks by dragging. The up/down buttons are the
        // primary path -- they work from the keyboard, which this does not --
        // so this is an accelerator and is allowed to be simple.
        //
        // Deliberately does NOT reorder the DOM. It computes the order the drop
        // implies and pushes it; the server re-renders, and the server's order
        // is the only one that gets saved. That is what keeps the DOM and the
        // document from ever disagreeing.
        export default {
          mounted() {
            this.dragId = null

            this.el.addEventListener("dragstart", (e) => {
              const card = e.target.closest("[data-block-id]")
              if (!card) return
              this.dragId = card.dataset.blockId
              card.classList.add("opacity-40")
              e.dataTransfer.effectAllowed = "move"
              // Firefox refuses to start a drag with nothing on the transfer.
              e.dataTransfer.setData("text/plain", this.dragId)
            })

            this.el.addEventListener("dragover", (e) => {
              e.preventDefault()
              e.dataTransfer.dropEffect = "move"
            })

            this.el.addEventListener("drop", (e) => {
              e.preventDefault()
              const over = e.target.closest("[data-block-id]")
              if (!over || !this.dragId || over.dataset.blockId === this.dragId) return

              const ids = [...this.el.querySelectorAll("[data-block-id]")]
                .map((n) => n.dataset.blockId)
                .filter((id) => id !== this.dragId)

              const at = ids.indexOf(over.dataset.blockId)
              // Dropping on the lower half of a card lands after it.
              const box = over.getBoundingClientRect()
              const after = e.clientY > box.top + box.height / 2
              ids.splice(after ? at + 1 : at, 0, this.dragId)

              this.pushEvent("reorder_blocks", {ids})
            })

            this.el.addEventListener("dragend", () => {
              this.dragId = null
              this.el
                .querySelectorAll(".opacity-40")
                .forEach((n) => n.classList.remove("opacity-40"))
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
