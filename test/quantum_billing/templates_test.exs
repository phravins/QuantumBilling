defmodule QuantumBilling.TemplatesTest do
  @moduledoc """
  Templates carry the design a customer's invoices are printed with, so the
  rules that matter here are about what is allowed to change and when.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBilling.Templates.InvoiceTemplate
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout

  defp classic_xml, do: Layout.to_xml(Catalog.classic())

  defp create(attrs) do
    {:ok, template} =
      Templates.create_template(
        Map.merge(%{"name" => "Test", "layout_xml" => classic_xml()}, attrs)
      )

    template
  end

  describe "ensure_default/0" do
    test "seeds one template and is idempotent" do
      assert Templates.default_template() == nil

      first = Templates.ensure_default()
      assert first.is_default
      assert first.name == "Classic"

      assert Templates.ensure_default().id == first.id
      assert length(Templates.list_templates()) == 1
    end

    # Seeds the stock layout. An installation that had customised its invoices
    # before designs existed had those settings captured into a template by the
    # migration that dropped the old columns, so this path only ever runs for an
    # installation that has none.
    test "seeds the stock layout" do
      template = Templates.ensure_default()
      items = template |> Templates.document_of() |> block(:items)

      assert template.accent == "#18181b"
      assert Enum.map(items.children, & &1.field) == Catalog.item_fields()
    end
  end

  describe "set_default/1" do
    test "clears the previous default" do
      first = Templates.ensure_default()
      second = create(%{"name" => "Second"})

      {:ok, second} = Templates.set_default(second)

      assert second.is_default
      refute Repo.reload!(first).is_default
      assert Templates.default_template().id == second.id
    end

    # The partial unique index is the thing keeping "which template does a new
    # invoice get" from being answered by row order, so assert it actually bites
    # rather than trusting the application to be careful.
    test "a second default cannot be written directly" do
      Templates.ensure_default()

      assert {:error, changeset} =
               Templates.create_template(%{
                 "name" => "Sneaky",
                 "layout_xml" => classic_xml(),
                 "is_default" => true
               })

      refute changeset.valid?
    end
  end

  describe "duplicate_template/1" do
    test "copies the design without copying the default flag" do
      original = Templates.ensure_default()

      {:ok, copy} = Templates.duplicate_template(original)

      assert copy.name == "Classic copy"
      assert copy.layout_xml == original.layout_xml
      assert copy.accent == original.accent
      refute copy.is_default
    end

    test "editing the copy leaves the original alone" do
      original = Templates.ensure_default()
      {:ok, copy} = Templates.duplicate_template(original)

      edited = copy |> Templates.document_of() |> drop(:amount_in_words)
      {:ok, _copy} = Templates.update_template(copy, %{"layout_xml" => Layout.to_xml(edited)})

      assert original
             |> Repo.reload!()
             |> Templates.document_of()
             |> Document.has_type?(:amount_in_words)
    end

    test "a second copy does not collide with the first" do
      original = Templates.ensure_default()

      {:ok, _first} = Templates.duplicate_template(original)
      {:ok, second} = Templates.duplicate_template(original)

      assert second.name == "Classic copy 2"
    end
  end

  describe "create_template/1 and update_template/2" do
    test "malformed XML is a changeset error on the layout, not a crash" do
      assert {:error, changeset} =
               Templates.create_template(%{"name" => "Broken", "layout_xml" => "<not-xml"})

      assert %{layout_xml: [message]} = errors_on(changeset)
      assert message =~ "not valid XML"
    end

    test "a layout with no item table is refused" do
      xml = Catalog.classic() |> drop(:items) |> Layout.to_xml()

      assert {:error, changeset} =
               Templates.create_template(%{"name" => "Itemless", "layout_xml" => xml})

      assert %{layout_xml: [message]} = errors_on(changeset)
      assert message =~ "items"
    end

    test "an accent that is not a colour is refused" do
      assert {:error, changeset} =
               Templates.create_template(%{
                 "name" => "Loud",
                 "layout_xml" => classic_xml(),
                 "accent" => "red"
               })

      assert %{accent: _} = errors_on(changeset)
    end

    test "two live templates cannot share a name" do
      create(%{"name" => "Taken"})

      assert {:error, changeset} =
               Templates.create_template(%{"name" => "Taken", "layout_xml" => classic_xml()})

      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "delete_template/1" do
    test "removes a template nothing points at" do
      template = create(%{"name" => "Unused"})

      assert {:ok, _template} = Templates.delete_template(template)
      assert Templates.list_templates() == []
    end
  end

  describe "document_for/1" do
    # A page view is a read. Rendering an invoice on a fresh install must not
    # insert a row, and must still print what the application printed before
    # templates existed.
    test "falls back to the stock layout when no design exists" do
      {document, accent, _logo} = Templates.document_for(%QuantumBilling.Invoices.Invoice{})

      assert accent == "#18181b"
      assert Enum.map(document.blocks, & &1.type) == Enum.map(Catalog.classic().blocks, & &1.type)
      assert Templates.default_template() == nil, "rendering must not create a design"
    end

    test "uses the default template once one exists" do
      Templates.ensure_default()
      second = create(%{"name" => "Bold", "accent" => "#B91C1C"})
      {:ok, _second} = Templates.set_default(second)

      {_document, accent, _logo} = Templates.document_for(%QuantumBilling.Invoices.Invoice{})

      assert accent == "#B91C1C"
    end

    test "the logo comes from the organisation, not the template" do
      Templates.ensure_default()

      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"doc_logo_path" => "/uploads/mark.png"},
          :customization
        )

      {_document, _accent, logo} = Templates.document_for(%QuantumBilling.Invoices.Invoice{})

      assert logo == "/uploads/mark.png"
    end
  end

  # These encode the whole structure-frozen / branding-live decision. If a future
  # change makes a template edit reach documents that have already been sent,
  # this is what should go red.
  describe "the layout an issued invoice keeps" do
    setup do
      template = Templates.ensure_default()
      {:ok, invoice} = Invoices.create_invoice(invoice_attrs())

      %{template: template, invoice: invoice}
    end

    test "the design is frozen onto the invoice at issue", %{template: template, invoice: invoice} do
      assert invoice.template_id == template.id
      assert invoice.layout_xml == template.layout_xml
    end

    test "editing the template does not change an invoice already issued",
         %{template: template, invoice: invoice} do
      {:ok, invoice} = Invoices.update_invoice(invoice, %{"status" => "E-Invoice Generated"})

      trimmed = template |> Templates.document_of() |> drop(:amount_in_words)

      {:ok, _template} =
        Templates.update_template(template, %{"layout_xml" => Layout.to_xml(trimmed)})

      {document, _accent, _logo} = Templates.document_for(Repo.reload!(invoice))

      assert Document.has_type?(document, :amount_in_words),
             "a template edit rewrote a document that had already been issued"
    end

    # The other half of the rule: a rebrand is meant to reach everything.
    test "recolouring the template does reach an invoice already issued",
         %{template: template, invoice: invoice} do
      {:ok, invoice} = Invoices.update_invoice(invoice, %{"status" => "E-Invoice Generated"})
      {:ok, _template} = Templates.update_template(template, %{"accent" => "#B91C1C"})

      {_document, accent, _logo} = Templates.document_for(Repo.reload!(invoice))

      assert accent == "#B91C1C"
    end

    test "a draft picks up a template edit when it is next saved",
         %{template: template, invoice: invoice} do
      trimmed = template |> Templates.document_of() |> drop(:amount_in_words)

      {:ok, _template} =
        Templates.update_template(template, %{"layout_xml" => Layout.to_xml(trimmed)})

      assert invoice.status == "Draft"
      {:ok, invoice} = Invoices.update_invoice(invoice, %{"remarks" => "Touched"})

      {document, _accent, _logo} = Templates.document_for(invoice)
      refute Document.has_type?(document, :amount_in_words)
    end

    # Judging by the stored status, not the params, is what makes this hold: a
    # save that also flips the status must not re-freeze the document on its way
    # out of draft.
    test "a non-draft snapshot cannot be rewritten even when sent explicitly",
         %{invoice: invoice} do
      {:ok, invoice} = Invoices.update_invoice(invoice, %{"status" => "E-Invoice Generated"})
      original = invoice.layout_xml

      {:ok, invoice} =
        Invoices.update_invoice(invoice, %{"layout_xml" => "<invoice-template version=\"1\"/>"})

      assert invoice.layout_xml == original
    end

    test "an invoice issued before layouts existed falls through to the default",
         %{invoice: invoice} do
      {:ok, invoice} =
        invoice
        |> Ecto.Changeset.change(%{layout_xml: nil, template_id: nil})
        |> Repo.update()

      {document, _accent, _logo} = Templates.document_for(invoice)

      assert Document.has_type?(document, :items)
    end
  end

  describe "document_of/1" do
    # A saved invoice being unopenable is a worse failure than being drawn with
    # the wrong design. The changeset already refuses to *write* invalid XML.
    test "a row whose XML no longer parses renders the stock layout" do
      template = %InvoiceTemplate{layout_xml: "<broken"}

      assert Templates.document_of(template).blocks == Catalog.classic().blocks
    end
  end

  defp invoice_attrs do
    %{
      "invoice_date" => Date.to_iso8601(~D[2026-04-18]),
      "place_of_supply" => "Maharashtra (27)",
      "client_name" => "Northwind Traders",
      "items" => %{
        "0" => %{"description" => "Design retainer", "quantity" => "2", "rate" => "500"}
      }
    }
  end

  defp block(document, type), do: Enum.find(document.blocks, &(&1.type == type))

  defp drop(document, type) do
    %{document | blocks: Enum.reject(document.blocks, &(&1.type == type))}
  end
end
