defmodule QuantumBilling.Repo.Migrations.DropAbsorbedDocumentCustomization do
  @moduledoc """
  Removes the document customization columns that invoice layouts absorbed.

  Each of these became structure in an invoice layout: the six `doc_show_*`
  booleans are now the presence or absence of a column or a block, the heading
  and footer are the text of their blocks, and the accent moved onto
  `invoice_templates` because it is per-design rather than per-organisation.
  `doc_template` was never read by anything even before that.

  `doc_logo_path` stays. A logo belongs to the organisation — one company, one
  logo — and a copy per design would mean uploading it repeatedly and forgetting
  one.

  Separate from `create_invoice_templates.exs` on purpose. That migration created
  the table without touching these, so for the releases in between a rollback was
  a code revert rather than a data-loss event.

  ## This one does move data, unlike the others

  `Templates.ensure_default/0` seeds a design from these columns the first time
  somebody opens the Customization panel or the design pad. An installation that
  upgrades without doing either has never seeded one — so dropping the columns
  here would silently discard whatever they had customised, with no second
  chance. A drop is a one-way door, and capturing the values first is the only
  point at which they can still be read.

  It reads them with raw SQL rather than through `Organization`, because by the
  time this runs the schema no longer declares the fields. `Layout.from_legacy/1`
  accepts a plain map for exactly this reason.
  """
  use Ecto.Migration

  alias QuantumBilling.Repo
  alias QuantumBillingWeb.InvoiceDoc.Layout

  @columns ~w(doc_accent_color doc_heading doc_footer_text doc_show_hsn
              doc_show_unit doc_show_tax_rate doc_show_remarks
              doc_show_amount_words doc_show_cess)a

  def up do
    preserve_as_template()
    drop_columns()
  end

  # Irreversible by design: the values are absorbed into a layout, and there is
  # no honest way to project a layout back onto nine booleans a user may since
  # have moved well beyond.
  def down do
    raise Ecto.MigrationError,
      message:
        "Document customization columns cannot be restored — their values now live " <>
          "in invoice_templates.layout_xml. Restore from a backup instead."
  end

  defp preserve_as_template do
    with %{rows: [values], columns: names} <- read_settings(),
         false <- template_exists?() do
      settings = names |> Enum.map(&String.to_atom/1) |> Enum.zip(values) |> Map.new()

      xml = settings |> Layout.from_legacy() |> Layout.to_xml()
      accent = settings[:doc_accent_color] || "#18181b"
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.query!(
        """
        INSERT INTO invoice_templates
          (name, layout_xml, accent, is_default, inserted_at, updated_at)
        VALUES ($1, $2, $3, true, $4, $4)
        ON CONFLICT DO NOTHING
        """,
        ["Classic", xml, accent, now]
      )
    end
  end

  defp read_settings do
    case Repo.query!("SELECT #{Enum.join(@columns, ", ")} FROM organization_settings LIMIT 1") do
      %{rows: []} -> nil
      result -> result
    end
  end

  defp template_exists? do
    %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM invoice_templates")
    count > 0
  end

  defp drop_columns do
    alter table(:organization_settings) do
      remove :doc_template, :string, null: false, default: "Classic"
      remove :doc_accent_color, :string, null: false, default: "#18181b"
      remove :doc_heading, :string
      remove :doc_footer_text, :text
      remove :doc_show_hsn, :boolean, null: false, default: true
      remove :doc_show_unit, :boolean, null: false, default: true
      remove :doc_show_tax_rate, :boolean, null: false, default: true
      remove :doc_show_remarks, :boolean, null: false, default: true
      remove :doc_show_amount_words, :boolean, null: false, default: true
      remove :doc_show_cess, :boolean, null: false, default: false
    end
  end
end
