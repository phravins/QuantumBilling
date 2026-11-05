defmodule QuantumBilling.Templates.InvoiceTemplate do
  @moduledoc """
  A named invoice layout.

  `layout_xml` is structure, frozen onto an invoice when issued. `accent` is a
  separate column, so recolouring restyles past invoices. The logo belongs to
  the organisation. `changeset/2` parses and validates the XML, so every
  write path is checked.
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
    # Written into a style attribute, so only a hex colour.
    |> validate_format(:accent, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a hex colour like #1D4ED8"
    )
    |> validate_layout()
    |> unique_constraint(:name, message: "is already taken by another template")
    |> unique_constraint(:is_default, name: :invoice_templates_one_default_index)
  end

  @doc "Archives a template still used by invoices, instead of deleting it."
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
