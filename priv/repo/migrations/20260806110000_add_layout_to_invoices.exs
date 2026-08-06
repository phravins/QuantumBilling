defmodule QuantumBilling.Repo.Migrations.AddLayoutToInvoices do
  @moduledoc """
  The design an invoice was issued under, frozen onto the invoice.

  `create_invoices.exs` already argues that the client and company details are
  copied rather than read live, so a saved invoice keeps showing what was
  actually billed. The layout belongs on the same side of that line, and this is
  the column that puts it there.

  Under Rule 46 of the CGST Rules an invoice must carry specified particulars,
  and the design pad by construction lets a user delete blocks. Were the layout
  read live, removing the amount-in-words block in March would retroactively
  change every invoice issued in January, and a client asking for a duplicate
  copy would receive a document that differs from the one already in their
  records.

  Branding deliberately stays live. `template_id` keeps pointing at the design so
  the accent — and the organisation's logo — still follow a rebrand, which is the
  behaviour `add_document_customization_to_organization_settings.exs` set out.

  Existing invoices are left with a null `layout_xml`. They fall through to the
  default template, which at this moment *is* the layout they were printed with,
  so nothing is misrepresented and no backfill is needed.
  """
  use Ecto.Migration

  def change do
    alter table(:invoices) do
      # Nilify rather than restrict: the snapshot below is what actually renders
      # the document, so losing the pointer costs the record of which design was
      # used, not the ability to reprint. The UI archives instead of deleting
      # when invoices point at a template, to keep even that.
      add :template_id, references(:invoice_templates, on_delete: :nilify_all)
      add :layout_xml, :text
    end

    create index(:invoices, [:template_id])
  end
end
