defmodule QuantumBilling.Templates.InvoiceTemplate do
  @moduledoc """
  A named invoice layout.

  ## What is in the XML and what is beside it

  `layout_xml` holds *structure* — which blocks the document has, in what order,
  which columns the item table carries and what they are labelled. `accent` sits
  beside it as a column because it is *branding*, and the two are read at
  different times: structure is frozen onto an invoice when it is issued, while
  branding stays live so recolouring restyles invoices already sent. Putting the
  accent inside the layout would freeze it along with everything else.

  The logo is not here at all. It belongs to the organisation — one company, one
  logo — and a copy per template would mean uploading it three times and
  forgetting one.

  ## The XML is validated, not trusted

  `changeset/2` parses `layout_xml` and runs `Layout.validate/1` over the result,
  so a template that would render a document with no line items cannot be saved.
  Doing it here rather than in the design pad means the same check covers a
  duplicate, an import, or anything else that writes a row later.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBillingWeb.InvoiceDoc.Layout

  schema "invoice_templates" do
    field :name, :string
    field :layout_xml, :string
    field :accent, :string, default: "#18181b"
    field :is_default, :boolean, default: false
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @castable ~w(name layout_xml accent is_default)a

  def changeset(template, attrs) do
    template
    |> cast(attrs, @castable)
    |> validate_required([:name, :layout_xml])
    |> validate_length(:name, max: 60)
    # Same rule and same reason as the organisation's accent: it is written
    # into a style attribute, so it has to be a colour and nothing else.
    |> validate_format(:accent, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a hex colour like #1D4ED8"
    )
    |> validate_layout()
    |> unique_constraint(:name, message: "is already taken by another template")
    |> unique_constraint(:is_default, name: :invoice_templates_one_default_index)
  end

  @doc """
  Marks a template archived rather than deleting it.

  Used when invoices still point at it: the row is what records which design
  they were issued under.
  """
  def archive_changeset(template) do
    change(template, archived_at: DateTime.utc_now(:second), is_default: false)
  end

  defp validate_layout(changeset) do
    case get_change(changeset, :layout_xml) do
      nil ->
        changeset

      xml ->
        case Layout.parse(xml) do
          {:ok, document} ->
            case Layout.validate(document) do
              :ok -> changeset
              {:error, messages} -> add_error(changeset, :layout_xml, Enum.join(messages, " "))
            end

          {:error, message} ->
            add_error(changeset, :layout_xml, message)
        end
    end
  end
end
