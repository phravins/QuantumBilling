defmodule QuantumBilling.Templates do
  @moduledoc """
  Named invoice layouts.

  ## Seeded on read

  The first design is created by `ensure_default/0`, the first time something
  needs to write one. An installation that had customised its invoices before
  designs existed had those settings captured into a template by the migration
  that dropped the old columns, so this only ever runs for an installation that
  has none.

  Nothing on a read path calls it. Rendering an invoice is a read and a page view
  must not insert a row; issuing an invoice must not either, because two saves
  racing to create the first design contend on the partial unique index over
  `is_default` and deadlock. Both fall back to the stock layout instead.

  ## Structure and branding are resolved separately

  `document_for/1` returns the layout, the accent and the logo as three values
  because they come from three places and are read at different times. The
  layout is frozen onto the invoice at issue; the accent is read live from the
  template; the logo is read live from the organisation. See
  `QuantumBilling.Templates.InvoiceTemplate` for why.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
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

  @doc """
  The default template, creating it from the organisation's settings first time.

  Call this from anything that is about to write — the settings panel, the
  design pad. Read paths should use `default_template/0` or `document_for/1`,
  which do not insert.
  """
  def ensure_default do
    case default_template() do
      nil -> seed_default()
      template -> template
    end
  end

  @doc "Builds a changeset, for forms."
  def change_template(%InvoiceTemplate{} = template, attrs \\ %{}) do
    InvoiceTemplate.changeset(template, attrs)
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

  @doc """
  Copies a template under a fresh name.

  The copy is never the default: duplicating a design to experiment with should
  not change what the next invoice comes out as.
  """
  def duplicate_template(%InvoiceTemplate{} = template) do
    create_template(%{
      "name" => copy_name(template.name),
      "layout_xml" => template.layout_xml,
      "accent" => template.accent,
      "is_default" => false
    })
  end

  @doc """
  Makes `template` the default, clearing the previous one.

  A transaction because the partial unique index on `is_default` is not
  deferrable: setting the new flag before clearing the old one violates it
  mid-statement, so the two updates have to be ordered inside one transaction.
  """
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

  @doc """
  Archives a template so it stops appearing without losing what it recorded.

  Used instead of deletion when invoices point at it: the row is the record of
  which design they were issued under.
  """
  def archive_template(%InvoiceTemplate{} = template) do
    template
    |> InvoiceTemplate.archive_changeset()
    |> Repo.update()
    |> broadcast()
  end

  @doc """
  Deletes a template, or archives it when invoices still reference it.

  Archiving rather than refusing keeps the action predictable — the template
  disappears from the list either way, and the caller does not have to know
  whether anything happens to point at it.
  """
  def delete_template(%InvoiceTemplate{} = template) do
    if referenced?(template) do
      archive_template(template)
    else
      template |> Repo.delete() |> broadcast()
    end
  end

  @doc """
  What to render `invoice` with: its layout, its accent, and the logo.

  ## Resolution order

  Structure comes from the invoice's own frozen `layout_xml` when it has one,
  then from the template it was issued under, then from the default, and finally
  from the stock layout. The first step is what stops a template edit rewriting
  documents that have already been sent.

  Branding does *not* follow that order — the accent is read live from the
  template and the logo live from the organisation, so a rebrand reaches every
  invoice rather than only the next one.

  An invoice issued before this column existed has no snapshot and falls through
  to the default, which at that point is the layout it was printed with.
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

  @doc """
  The parsed layout of a template.

  A row whose XML no longer parses renders the stock layout rather than raising:
  a saved invoice being unopenable is a worse failure than it being drawn with
  the wrong design, and the changeset already refuses to *write* invalid XML.
  """
  def document_of(%InvoiceTemplate{layout_xml: xml}), do: parse_or_classic(xml)

  defp parse_or_classic(xml) do
    case Layout.parse(xml) do
      {:ok, document} -> document
      {:error, _message} -> Catalog.classic()
    end
  end

  # The stock layout. An installation that had customised its invoices before
  # designs existed had those settings captured into a template by the migration
  # that dropped the columns, so there is nothing left here to carry across.
  defp seed_default do
    %InvoiceTemplate{}
    |> InvoiceTemplate.changeset(%{
      "name" => "Classic",
      "layout_xml" => Catalog.classic() |> Layout.to_xml(),
      "accent" => @default_accent,
      "is_default" => true
    })
    |> Repo.insert(on_conflict: :nothing)

    # Re-read rather than trusting the insert: on a conflict it comes back
    # without an id, because the row that exists belongs to whoever won the
    # race. Same reasoning as `Settings.ensure_organization/0`.
    default_template() || Repo.one(from t in InvoiceTemplate, order_by: [asc: t.id], limit: 1)
  end

  defp referenced?(%InvoiceTemplate{id: nil}), do: false

  # Phase 3 adds `invoices.template_id`. Until the column exists there is
  # nothing that can point at a template, so nothing to preserve.
  defp referenced?(%InvoiceTemplate{} = template) do
    if :template_id in Invoice.__schema__(:fields) do
      Repo.exists?(from i in Invoice, where: i.template_id == ^template.id)
    else
      false
    end
  end

  defp copy_name(name) do
    taken = Repo.all(from t in InvoiceTemplate, where: is_nil(t.archived_at), select: t.name)

    Enum.find_value(
      ["#{name} copy" | Enum.map(2..50, &"#{name} copy #{&1}")],
      "#{name} #{System.unique_integer([:positive])}",
      fn candidate -> if candidate not in taken, do: candidate end
    )
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  # Broadcast from, not to: the window that saved has already re-rendered with
  # its own result, and handling its own echo would rebuild the canvas it is
  # still working in.
  defp broadcast({:ok, %InvoiceTemplate{} = template} = result) do
    Events.broadcast_from(Events.invoice_templates_topic(), {:invoice_template_changed, template})
    result
  end

  defp broadcast(result), do: result
end
