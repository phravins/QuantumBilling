defmodule QuantumBillingWeb.InvoiceDocumentTest do
  @moduledoc """
  The invoice is rendered twice — on screen and for print — from separate
  markup. These assert both honour the same customization settings, because a
  toggle that only reaches one of them is worse than no toggle at all.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

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

  defp customize(attrs) do
    {:ok, organization} =
      Settings.update_section(Settings.get_organization(), attrs, :customization)

    organization
  end

  # Both renderings of the same invoice, so every assertion below is made twice.
  defp both(conn, invoice) do
    {:ok, _view, screen} = live(conn, ~p"/invoices/#{invoice.id}")
    printed = conn |> get(~p"/invoices/#{invoice.id}/pdf") |> html_response(200)

    %{screen: screen, printed: printed}
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
      customize(%{
        "doc_show_hsn" => "false",
        "doc_show_unit" => "false",
        "doc_show_tax_rate" => "false"
      })

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
      customize(%{"doc_accent_color" => "#1D4ED8"})

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ "#1D4ED8"
      assert printed =~ "#1D4ED8"
    end

    test "a heading overrides the invoice type on both", %{conn: conn, invoice: invoice} do
      customize(%{"doc_heading" => "ORIGINAL FOR RECIPIENT"})

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
      customize(%{"doc_footer_text" => "Thank you for your business."})

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ "Thank you for your business."
      assert printed =~ "Thank you for your business."
    end

    # The app sidebar carries the same mark, so the screen page always contains
    # one. What matters is whether the *document* adds a second.
    defp marks(html), do: html |> String.split("hero-receipt-percent") |> length() |> Kernel.-(1)

    test "the fallback mark shows while no logo is uploaded", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)

      assert marks(screen) == 2, "expected the sidebar mark and the document mark"
      assert printed =~ "QuantumBilling"
    end

    test "an uploaded logo replaces the mark on both", %{conn: conn, invoice: invoice} do
      customize(%{"doc_logo_path" => "/uploads/pretend-logo.png"})

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert screen =~ "/uploads/pretend-logo.png"
      assert printed =~ "/uploads/pretend-logo.png"

      assert marks(screen) == 1, "the document should no longer add its own mark"
      # The print page has no sidebar, so its mark should be gone entirely.
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

      customize(%{"doc_show_remarks" => "false"})

      %{screen: screen, printed: printed} = both(conn, invoice)
      refute screen =~ "Delivered against PO-8842."
      refute printed =~ "Delivered against PO-8842."
    end

    test "amount in words hides on both", %{conn: conn, invoice: invoice} do
      %{screen: screen, printed: printed} = both(conn, invoice)
      assert screen =~ "Amount in Words"
      assert printed =~ "Amount in Words"

      customize(%{"doc_show_amount_words" => "false"})

      %{screen: screen, printed: printed} = both(conn, invoice)
      refute screen =~ "Amount in Words"
      refute printed =~ "Amount in Words"
    end

    # The setting alone is not enough: an always-zero cess row would teach the
    # reader nothing, so a figure has to exist too.
    test "cess stays hidden when enabled but zero", %{conn: conn, invoice: invoice} do
      customize(%{"doc_show_cess" => "true"})

      %{screen: screen, printed: printed} = both(conn, invoice)

      assert invoice.cess_amount == 0
      refute screen =~ ">Cess<"
      refute printed =~ ">Cess<"
    end
  end
end
