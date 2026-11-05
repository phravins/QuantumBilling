defmodule QuantumBilling.Templates do
  @moduledoc """
  Named invoice layouts (designs).

  The first design is created by `ensure_default/0` on the first write; read
  paths never insert. `document_for/1` returns layout, accent and logo
  separately: the layout is frozen on the invoice, the accent and logo are read
  live. Deleting archives a design into the Bin.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias QuantumBilling.Audit
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates.InvoiceTemplate
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  @default_accent "#18181b"

  @doc "Subscribes the caller to template changes."
  def subscribe, do: Events.subscribe(Events.invoice_templates_topic())

  @doc "Every template that has not been archived, oldest first."
  def list_templates do
    Repo.all(from t in InvoiceTemplate, where: is_nil(t.archived_at), order_by: [asc: t.id])
  end

  @doc "Every archived template — the designs in the Bin — most recently archived first."
  def list_archived_templates do
    Repo.all(
      from t in InvoiceTemplate,
        where: not is_nil(t.archived_at),
        order_by: [desc: t.archived_at, desc: t.id]
    )
  end

  @doc "One archived template by id, or `nil` — including for an id that is not a number."
  def get_archived_template(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        Repo.one(from t in InvoiceTemplate, where: t.id == ^int_id and not is_nil(t.archived_at))

      _not_an_id ->
        nil
    end
  end

  @doc "One template by id, or `nil`. Archived templates are still readable."
  def get_template(id), do: Repo.get(InvoiceTemplate, id)

  @doc "One template by id, raising when it does not exist."
  def get_template!(id), do: Repo.get!(InvoiceTemplate, id)

  @doc "The default template, or `nil` when none has been created yet."
  def default_template do
    Repo.one(
      from t in InvoiceTemplate,
        where: t.is_default and is_nil(t.archived_at),
        limit: 1
    )
  end

  @doc "The default template, created on first use. Only for write paths."
  def ensure_default do
    case default_template() do
      nil -> seed_default()
      template -> template
    end
  end

  @doc "Creates a template."
  def create_template(attrs) do
    %InvoiceTemplate{}
    |> InvoiceTemplate.changeset(attrs)
    |> Repo.insert()
    |> broadcast()
  end

  @doc "Updates a template."
  def update_template(%InvoiceTemplate{} = template, attrs) do
    template
    |> InvoiceTemplate.changeset(attrs)
    |> Repo.update()
    |> broadcast()
  end

  @doc "Copies a template under a new name. The copy is never the default."
  def duplicate_template(%InvoiceTemplate{} = template) do
    create_template(%{
      "name" => copy_name(template.name),
      "layout_xml" => template.layout_xml,
      "accent" => template.accent,
      "is_default" => false
    })
  end

  @doc "Creates a design from a parsed document under `name` or the next free variant."
  def create_from_document(%QuantumBillingWeb.InvoiceDoc.Document{} = document, name) do
    name = name |> to_string() |> String.trim() |> String.slice(0, 50)
    name = if name == "", do: "Design", else: name

    create_template(%{
      "name" => free_name([name | Enum.map(2..50, &"#{name} #{&1}")], name),
      "layout_xml" => Layout.to_xml(document),
      "accent" => current_accent(),
      "is_default" => false
    })
  end

  @doc "Creates a design from one of `Catalog.presets/0`."
  def create_from_preset(key) do
    case Catalog.preset(key) do
      nil -> {:error, :unknown_preset}
      document -> create_from_document(document, Catalog.preset_name(key))
    end
  end

  @max_import_bytes 256_000

  @doc "The largest design file `import_layout/3` accepts, in bytes."
  def max_import_bytes, do: @max_import_bytes

  @doc """
  Creates a design from an exported layout file.

  Parsed with the same allowlist; DTDs are refused. Image paths this business
  doesn't own are blanked.
  """
  def import_layout(xml, name, keep? \\ &QuantumBilling.DesignAssets.owned?/1)

  def import_layout(xml, _name, _keep?) when byte_size(xml) > @max_import_bytes do
    {:error, "That file is larger than #{div(@max_import_bytes, 1000)}KB."}
  end

  def import_layout(xml, name, keep?) when is_binary(xml) do
    cond do
      not String.valid?(xml) ->
        {:error, "That file is not a text design file."}

      String.contains?(xml, ["<!DOCTYPE", "<!ENTITY", "<!doctype"]) ->
        {:error, "Design files cannot contain a DOCTYPE or entity declarations."}

      true ->
        with {:ok, document} <- Layout.parse(xml),
             :ok <- validate_import(document) do
          document
          |> Layout.strip_assets(keep?)
          |> create_from_document(name)
        end
    end
  end

  defp validate_import(document) do
    case Layout.validate(document) do
      :ok -> :ok
      {:error, messages} -> {:error, Enum.join(messages, " ")}
    end
  end

  defp current_accent do
    case default_template() do
      %InvoiceTemplate{accent: "#" <> _ = accent} -> accent
      _none -> @default_accent
    end
  end

  @doc "Makes `template` the default, clearing the previous one in one transaction."
  def set_default(%InvoiceTemplate{} = template) do
    Multi.new()
    |> Multi.update_all(
      :clear,
      from(t in InvoiceTemplate, where: t.is_default),
      set: [is_default: false]
    )
    |> Multi.update(:set, InvoiceTemplate.changeset(template, %{"is_default" => true}))
    |> Repo.transaction()
    |> case do
      {:ok, %{set: saved}} -> broadcast({:ok, saved})
      {:error, :set, changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "Archives a template without losing its record."
  def archive_template(%InvoiceTemplate{} = template) do
    template
    |> InvoiceTemplate.archive_changeset()
    |> Repo.update()
    |> broadcast()
  end

  @doc "Moves a template to the Bin. `opts` may carry `:user_id` for the audit entry."
  def delete_template(template, opts \\ [])

  def delete_template(%InvoiceTemplate{archived_at: %DateTime{}} = template, _opts) do
    {:ok, template}
  end

  def delete_template(%InvoiceTemplate{} = template, opts) do
    template
    |> archive_template()
    |> audited(:bin_invoice_template, opts)
  end

  @doc """
  Restores a template, renamed "Name (restored)" if the name was taken. Never as default.
  """
  def restore_template(%InvoiceTemplate{} = template, opts \\ []) do
    template
    |> Ecto.Changeset.change(archived_at: nil, name: restored_name(template))
    |> Ecto.Changeset.unique_constraint(:name, message: "is already taken by another template")
    |> Repo.update()
    |> broadcast()
    |> audited(:restore_invoice_template, opts)
  end

  @doc "Deletes an archived template. Returns `{:error, :in_use}` or `{:error, :not_in_bin}`."
  def purge_template(template, opts \\ [])

  def purge_template(%InvoiceTemplate{archived_at: nil}, _opts), do: {:error, :not_in_bin}

  def purge_template(%InvoiceTemplate{} = template, opts) do
    if referenced?(template) do
      {:error, :in_use}
    else
      template
      |> Repo.delete()
      |> broadcast()
      |> audited(:purge_invoice_template, opts)
    end
  end

  @doc "Whether any invoice was issued under this template."
  def in_use?(%InvoiceTemplate{} = template), do: referenced?(template)

  defp audited({:ok, %InvoiceTemplate{} = template} = result, action, opts) do
    Audit.log_event(action, "InvoiceTemplate", template.id,
      user_id: Keyword.get(opts, :user_id),
      details: %{name: template.name}
    )

    result
  end

  defp audited(result, _action, _opts), do: result

  @doc """
  What to render `invoice` with: `{layout, accent, logo}`.

  The layout comes from the invoice's snapshot, then its template, the default,
  then the stock layout. The accent and logo are always read live.
  """
  @spec document_for(Invoice.t()) ::
          {QuantumBillingWeb.InvoiceDoc.Document.t(), String.t(), String.t() | nil}
  def document_for(%Invoice{} = invoice) do
    organization = Settings.get_organization()
    logo = presence(organization.doc_logo_path)
    template = template_of(invoice) || default_template()

    accent = if template, do: template.accent, else: @default_accent

    document =
      cond do
        presence(invoice.layout_xml) -> parse_or_classic(invoice.layout_xml)
        template -> document_of(template)
        true -> Catalog.classic()
      end

    {document, accent, logo}
  end

  defp template_of(%Invoice{template_id: nil}), do: nil
  defp template_of(%Invoice{template_id: id}), do: get_template(id)

  @doc "The parsed layout of a template, or the stock layout if the XML no longer parses."
  def document_of(%InvoiceTemplate{layout_xml: xml}), do: parse_or_classic(xml)

  defp parse_or_classic(xml) do
    case Layout.parse(xml) do
      {:ok, document} -> document
      {:error, _message} -> Catalog.classic()
    end
  end

  defp seed_default do
    %InvoiceTemplate{}
    |> InvoiceTemplate.changeset(%{
      "name" => "Classic",
      "layout_xml" => Catalog.classic() |> Layout.to_xml(),
      "accent" => @default_accent,
      "is_default" => true
    })
    |> Repo.insert(on_conflict: :nothing)

    # Re-read: on a conflict the insert comes back without an id.
    default_template() || Repo.one(from t in InvoiceTemplate, order_by: [asc: t.id], limit: 1)
  end

  defp referenced?(%InvoiceTemplate{id: nil}), do: false

  # Includes binned invoices, which may be restored.
  defp referenced?(%InvoiceTemplate{} = template) do
    if :template_id in Invoice.__schema__(:fields) do
      Repo.exists?(from i in Invoice, where: i.template_id == ^template.id)
    else
      false
    end
  end

  defp copy_name(name) do
    free_name(["#{name} copy" | Enum.map(2..50, &"#{name} copy #{&1}")], name)
  end

  defp restored_name(%InvoiceTemplate{name: name}) do
    free_name([name, "#{name} (restored)" | Enum.map(2..50, &"#{name} (restored #{&1})")], name)
  end

  # Archived names don't count.
  defp free_name(candidates, name) do
    taken = Repo.all(from t in InvoiceTemplate, where: is_nil(t.archived_at), select: t.name)

    Enum.find_value(
      candidates,
      "#{name} #{System.unique_integer([:positive])}",
      fn candidate -> if candidate not in taken, do: candidate end
    )
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  # Broadcast from the saving window, which has already re-rendered.
  defp broadcast({:ok, %InvoiceTemplate{} = template} = result) do
    Events.broadcast_from(Events.invoice_templates_topic(), {:invoice_template_changed, template})
    result
  end

  defp broadcast(result), do: result
end
