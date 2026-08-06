defmodule QuantumBillingWeb.InvoiceDocumentTest do
  @moduledoc """
  The invoice is rendered on two surfaces — on screen, and standalone for print.
  These assert the two agree, because a setting that only reaches one of them is
  worse than no setting at all.

  Both now render through `InvoiceDoc.Renderer`, so agreement is structural
  rather than maintained by hand. These stay as the contract that says so: they
  are what caught the print page labelling its money columns differently from
  the screen, and they are what a future change to the renderer has to survive.

  What a document shows is now decided by its template rather than by the
  organisation's `doc_*` columns, so the helpers below edit the layout and
  re-save the draft — which is the path a user takes through the design pad.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Document
  alias QuantumBillingWeb.InvoiceDoc.Layout

  setup :register_and_log_in_user

  setup do
    {:ok, invoice} =
      Invoices.create_invoice(%{
        "invoice_date" => Date.to_iso8601(~D[2026-04-18]),
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "Northwind Traders",
        "remarks" => "Delivered against PO-8842.",
        "items" => %{
          "0" => %{
            "description" => "Design retainer",
            "hsn_sac" => "998311",
            "quantity" => "2",
            "unit" => "Hrs",
            "rate" => "500",
            "tax_rate" => "18"
          }
        }
      })

    %{invoice: invoice}
  end

  # Edits the default template's layout, then re-saves the draft so it picks the
  # change up. A non-draft would deliberately keep the document it was issued
  # with — `QuantumBilling.TemplatesTest` covers that rule; these are about what
  # the two surfaces do once a change has landed.
  defp relayout(invoice, fun) do
    template = Templates.ensure_default()
    document = fun.(Templates.document_of(template))

    {:ok, _template} =
      Templates.update_template(template, %{"layout_xml" => Layout.to_xml(document)})

    {:ok, invoice} = Invoices.update_invoice(invoice, %{})
    invoice
  end

  # Branding is read live, so it needs no re-save — which is the whole point of
  # keeping it off the layout.
  defp recolour(accent) do
    {:ok, template} = Templates.update_template(Templates.ensure_default(), %{"accent" => accent})
    template
  end

  defp drop_block(document, type) do
    %{document | blocks: Enum.reject(document.blocks, &(&1.type == type))}
  end

  # What the palette does. The stock layout carries no footer block until one is
  # added, because an organisation with no footer text has never printed one.
  defp add_block(document, type) do
    block = Catalog.new(type, Document.next_id(document))
    %{document | blocks: document.blocks ++ [block]}
  end

  defp drop_columns(document, fields) do
    update_block(document, :items, fn block ->
      %{block | children: Enum.reject(block.children, &(&1.field in fields))}
    end)
  end

  defp put_opt(document, type, key, value) do
    update_block(document, type, fn block -> %{block | opts: Map.put(block.opts, key, value)} end)
  end

  defp put_text(document, type, text) do
    update_block(document, type, fn block -> %{block | text: text} end)
  end

  defp update_block(document, type, fun) do
    %{document | blocks: Enum.map(document.blocks, &if(&1.type == type, do: fun.(&1), else: &1))}
  end

  defp set_logo(path) do
    {:ok, organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{"doc_logo_path" => path},
        :customization
      )

    organization
  end

  # Both renderings of the same invoice, so every assertion below is made twice.
  defp both(conn, invoice) do
    {:ok, _view, screen} = live(conn, ~p"/invoices/#{invoice.id}")
    printed = conn |> get(~p"/invoices/#{invoice.id}/pdf") |> html_response(200)

    %{screen: screen, printed: printed}
  end

  # The item table's column headers, in render order. Order is the thing a
  # renderer rewrite reshuffles silently — every column can still be present
  # while the document has become unreadable.
  defp item_columns(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("table thead th")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "column toggles" do
    test "HSN, Unit and Tax % show by default", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      for html <- [screen, printed] do
        assert html =~ "HSN / SAC"
        assert html =~ "Unit"
        assert html =~ "998311"
        assert html =~ "Hrs"
      end
    end

    test "turning them off removes them from both documents", %{conn: conn, invoice: invoice} do
      invoice = relayout(invoice, &drop_columns(&1, ["hsn_sac", "unit", "tax_rate"]))

      %{screen: screen, printed: printed} = both(conn, invoice)

      for {label, html} <- [{"screen", screen}, {"printed", printed}] do
        refute html =~ "HSN / SAC", "HSN column still on the #{label} document"
        refute html =~ "998311", "HSN value still on the #{label} document"
        refute html =~ ">Hrs<", "Unit value still on the #{label} document"

        # The columns that make it an invoice are never optional.
        assert html =~ "Design retainer"
        assert html =~ "Amount"
      end
    end
  end

  describe "branding" do
    test "the accent reaches both documents", %{conn: conn, invoice: invoice} do
      recolour("#1D4ED8")

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ "#1D4ED8"
      assert printed =~ "#1D4ED8"
    end

    test "a heading overrides the invoice type on both", %{conn: conn, invoice: invoice} do
      invoice = relayout(invoice, &put_opt(&1, :heading, :text, "ORIGINAL FOR RECIPIENT"))

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ "ORIGINAL FOR RECIPIENT"
      assert printed =~ "ORIGINAL FOR RECIPIENT"
    end

    test "without a heading each document falls back to the invoice's own type",
         %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ invoice.invoice_type
      assert printed =~ invoice.invoice_type
    end

    test "a footer reaches both documents", %{conn: conn, invoice: invoice} do
      invoice =
        relayout(invoice, fn document ->
          document |> add_block(:footer) |> put_text(:footer, "Thank you for your business.")
        end)

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ "Thank you for your business."
      assert printed =~ "Thank you for your business."
    end

    # Counts the mark the *document* draws. The app sidebar carries its own,
    # which is why this looks for the document's element rather than the icon:
    # both surfaces now draw the fallback as an inline SVG, because the `hero-*`
    # classes are CSS masks from a stylesheet the print page does not load.
    defp marks(html), do: html |> String.split("qb-doc__brand\"") |> length() |> Kernel.-(1)

    test "the fallback mark shows while no logo is uploaded", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      assert marks(screen) == 1, "the document should draw its own mark"
      assert marks(printed) == 1
      assert printed =~ "QuantumBilling"
    end

    test "an uploaded logo replaces the mark on both", %{conn: conn, invoice: invoice} do
      set_logo("/uploads/pretend-logo.png")

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ "/uploads/pretend-logo.png"
      assert printed =~ "/uploads/pretend-logo.png"

      assert marks(screen) == 0, "the document should no longer add its own mark"
      assert marks(printed) == 0
      # The print page has no sidebar, so its wordmark should be gone entirely.
      refute printed =~ "QuantumBilling"
    end
  end

  describe "optional blocks" do
    # Remarks used to render on screen but not in print. The toggle would have
    # been a switch that only worked in one direction.
    test "remarks render on both, and hide on both", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)
      assert screen =~ "Delivered against PO-8842."
      assert printed =~ "Delivered against PO-8842."

      invoice = relayout(invoice, &drop_block(&1, :remarks))

      %{screen: screen, printed: printed} = both(conn, invoice)
      refute screen =~ "Delivered against PO-8842."
      refute printed =~ "Delivered against PO-8842."
    end

    test "amount in words hides on both", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)
      assert screen =~ "Amount in Words"
      assert printed =~ "Amount in Words"

      invoice = relayout(invoice, &drop_block(&1, :amount_in_words))

      %{screen: screen, printed: printed} = both(conn, invoice)
      refute screen =~ "Amount in Words"
      refute printed =~ "Amount in Words"
    end

    # Presence in the layout is not enough: an always-zero cess row would teach
    # the reader nothing, so a figure has to exist too. The stock layout carries
    # the line already, at `when="non-zero"`.
    test "cess stays hidden when the figure is zero", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      assert invoice.cess_amount == 0
      refute screen =~ ">Cess<"
      refute printed =~ ">Cess<"
    end
  end

  # The assertions above check that a *setting* reaches both documents. These
  # check that the documents agree about everything else too — the parts no
  # toggle governs, which is exactly what a rewrite of the markup can reshuffle
  # without any test noticing.
  describe "parity of the parts no setting governs" do
    test "the item columns render in the same order on both", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      expected = [
        "#",
        "Item / Description",
        "HSN / SAC",
        "Qty",
        "Unit",
        "Rate (₹)",
        "Tax (%)",
        "Amount (₹)"
      ]

      assert item_columns(screen) == expected
      assert item_columns(printed) == expected
    end

    test "dropping a column shifts neither document's remaining order",
         %{conn: conn, invoice: invoice} do
      invoice = relayout(invoice, &drop_columns(&1, ["unit"]))

      %{screen: screen, printed: printed} = both(conn, invoice)

      expected = [
        "#",
        "Item / Description",
        "HSN / SAC",
        "Qty",
        "Rate (₹)",
        "Tax (%)",
        "Amount (₹)"
      ]

      assert item_columns(screen) == expected
      assert item_columns(printed) == expected
    end

    test "the identifying fields reach both", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      for html <- [screen, printed] do
        assert html =~ invoice.invoice_number
        assert html =~ "Maharashtra (27)"
        assert html =~ "Place of Supply"
        assert html =~ "Invoice Date"
        assert html =~ "Due Date"
        assert html =~ "Northwind Traders"
        assert html =~ "Bill To"
        assert html =~ "18 Apr 2026"
      end
    end

    test "every totals row reaches both", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      for html <- [screen, printed] do
        assert html =~ "Taxable Value"
        assert html =~ "Round Off"
        assert html =~ "Grand Total"
      end
    end

    # Which tax applies is decided by the supply, not by the template. Printing
    # IGST on an intra-state supply is a compliance error, so neither document
    # may be the one that gets it wrong.
    test "an intra-state supply shows CGST and SGST and no IGST on both",
         %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      for html <- [screen, printed] do
        assert html =~ "CGST"
        assert html =~ "SGST"
        refute html =~ "IGST"
      end
    end

    test "an inter-state supply shows IGST and no CGST or SGST on both", %{conn: conn} do
      # The snapshot is taken at issue, so the company's state has to be set
      # before the invoice is created rather than after.
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name" => "Your Company", "state" => "Karnataka (29)"},
          :general
        )

      {:ok, invoice} =
        Invoices.create_invoice(%{
          "invoice_date" => Date.to_iso8601(~D[2026-04-18]),
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "Northwind Traders",
          "items" => %{
            "0" => %{"description" => "Design retainer", "quantity" => "2", "rate" => "500"}
          }
        })

      %{screen: screen, printed: printed} = both(conn, invoice)

      for html <- [screen, printed] do
        assert html =~ "IGST"
        refute html =~ "CGST"
        refute html =~ "SGST"
      end
    end

    # HEEx does not interpolate inside a `<style>` element, and escaping the CSS
    # as ordinary content turns the child combinator into `&gt;` and drops the
    # rule. Both mistakes are silent — the page still renders, just unstyled.
    test "the stylesheet reaches both surfaces unescaped", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      for {label, html} <- [{"screen", screen}, {"printed", printed}] do
        assert html =~ "qb-doc__row > .qb-doc__cell",
               "the child combinator did not survive on the #{label} document"

        refute html =~ "{Phoenix.HTML.raw",
               "the #{label} document emitted the interpolation as literal text"
      end

      # The paper rules belong only to the page that is actually printed.
      assert printed =~ "@page"
      refute screen =~ "@page"
    end

    test "the line figures reach both", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      # Two hours at ₹500 — the rate, the quantity and the line total.
      for html <- [screen, printed] do
        assert html =~ "500.00"
        assert html =~ "1,000.00"
      end
    end
  end
end
