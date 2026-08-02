defmodule QuantumBillingWeb.InvoicesLiveTest do
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices

  setup :register_and_log_in_user

  defp create_invoice(over \\ %{}) do
    attrs =
      Map.merge(
        %{
          "invoice_date" => "2024-05-28",
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "V2V Technologies",
          "items" => %{
            "0" => %{
              "description" => "Web Development Services",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "50000",
              "tax_rate" => "18",
              "position" => "0"
            }
          }
        },
        over
      )

    {:ok, invoice} = Invoices.create_invoice(attrs)
    invoice
  end

  test "renders the page shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices")

    assert html =~ "Manage and track all your GST invoices"
    assert html =~ "Create New GST Invoice"
  end

  test "the create button links to the form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices")

    assert html =~ ~s(href="/invoices/new")
  end

  test "keeps the toolbar available", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/invoices")

    assert html =~ "Search invoices..."
    assert has_element?(view, "#invoice-search")
    assert html =~ "All Status"
  end

  test "shows an empty state rather than a bare table", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices")

    assert html =~ "No invoices yet"
    assert html =~ "GST invoices you create will appear here."
    refute html =~ "entries"
  end

  test "distinguishes an empty account from an empty search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices")

    html = view |> form("#invoice-search", %{"q" => "anything"}) |> render_change()

    assert html =~ "No invoices match these filters"
  end

  test "serves no sample records", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices")

    refute html =~ "V2V Technologies"
    refute html =~ "INV-2024-"
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/invoices")
  end

  describe "with invoices in the database" do
    test "a saved invoice appears in the table", %{conn: conn} do
      invoice = create_invoice()

      {:ok, _view, html} = live(conn, ~p"/invoices")

      assert html =~ invoice.invoice_number
      assert html =~ "V2V Technologies"
      refute html =~ "No invoices yet"
      refute html =~ "No invoices yet"
    end

    test "the eye icon opens the document", %{conn: conn} do
      invoice = create_invoice()

      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, ~s(a[href="/invoices/#{invoice.id}"]))
    end

    test "search finds an invoice by number and by client", %{conn: conn} do
      first = create_invoice()
      _second = create_invoice(%{"client_name" => "Insta Capital"})

      {:ok, view, _html} = live(conn, ~p"/invoices")

      by_client = view |> form("#invoice-search", %{"q" => "Insta"}) |> render_change()
      assert by_client =~ "Insta Capital"
      refute by_client =~ "V2V Technologies"

      by_number =
        view |> form("#invoice-search", %{"q" => first.invoice_number}) |> render_change()

      assert by_number =~ "V2V Technologies"
    end

    test "the status filter narrows to Draft", %{conn: conn} do
      create_invoice()

      {:ok, view, _html} = live(conn, ~p"/invoices")

      drafts = render_click(view, "filter_status", %{"status" => "Draft"})
      assert drafts =~ "V2V Technologies"
      refute drafts =~ "No invoices match these filters"

      generated = render_click(view, "filter_status", %{"status" => "E-Invoice Generated"})
      assert generated =~ "No invoices match these filters"
    end

    test "sorting by invoice number works over real rows", %{conn: conn} do
      create_invoice()
      create_invoice(%{"client_name" => "Insta Capital"})

      {:ok, view, _html} = live(conn, ~p"/invoices")

      html = render_click(view, "sort", %{"field" => "seq"})

      assert html =~ "V2V Technologies"
      assert html =~ "Insta Capital"
    end

    test "an invoice created elsewhere appears without a reload", %{conn: conn} do
      # The list already subscribed to invoice events from the realtime work;
      # this confirms create_invoice/1 actually broadcasts.
      {:ok, view, html} = live(conn, ~p"/invoices")
      assert html =~ "No invoices yet"

      create_invoice()

      assert render(view) =~ "V2V Technologies"
    end
  end
end
