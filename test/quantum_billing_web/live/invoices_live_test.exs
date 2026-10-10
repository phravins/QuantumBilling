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
    # Assert on `#invoice-<id>` rows: the notification bell also names the invoice
    # number and the client.
    test "a saved invoice appears in the table", %{conn: conn} do
      invoice = create_invoice()

      {:ok, view, html} = live(conn, ~p"/invoices")

      assert has_element?(view, "#invoice-#{invoice.id}", invoice.invoice_number)
      assert has_element?(view, "#invoice-#{invoice.id}", "V2V Technologies")
      refute html =~ "No invoices yet"
    end

    test "the eye icon opens the document", %{conn: conn} do
      invoice = create_invoice()

      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert has_element?(view, ~s(a[href="/invoices/#{invoice.id}"]))
    end

    test "search finds an invoice by number and by client", %{conn: conn} do
      first = create_invoice()
      second = create_invoice(%{"client_name" => "Insta Capital"})

      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> form("#invoice-search", %{"q" => "Insta"}) |> render_change()
      assert has_element?(view, "#invoice-#{second.id}")
      refute has_element?(view, "#invoice-#{first.id}")

      view |> form("#invoice-search", %{"q" => first.invoice_number}) |> render_change()
      assert has_element?(view, "#invoice-#{first.id}")
      refute has_element?(view, "#invoice-#{second.id}")
    end

    test "the status filter narrows to Draft", %{conn: conn} do
      invoice = create_invoice()

      {:ok, view, _html} = live(conn, ~p"/invoices")

      drafts = render_click(view, "filter_status", %{"status" => "Draft"})
      assert has_element?(view, "#invoice-#{invoice.id}")
      refute drafts =~ "No invoices match these filters"

      generated = render_click(view, "filter_status", %{"status" => "E-Invoice Generated"})
      refute has_element?(view, "#invoice-#{invoice.id}")
      assert generated =~ "No invoices match these filters"
    end

    test "sorting by invoice number works over real rows", %{conn: conn} do
      first = create_invoice()
      second = create_invoice(%{"client_name" => "Insta Capital"})

      {:ok, view, _html} = live(conn, ~p"/invoices")

      render_click(view, "sort", %{"field" => "seq"})

      assert has_element?(view, "#invoice-#{first.id}")
      assert has_element?(view, "#invoice-#{second.id}")
    end

    test "an invoice created elsewhere appears without a reload", %{conn: conn} do
      # Scoped to the row, not the notification bell.
      {:ok, view, html} = live(conn, ~p"/invoices")
      assert html =~ "No invoices yet"

      invoice = create_invoice()

      assert has_element?(view, "#invoice-#{invoice.id}")
    end

    # The Clients page links here with `?q=<client>`.
    test "a search carried in the URL is applied on the first render", %{conn: conn} do
      first = create_invoice()
      second = create_invoice(%{"client_name" => "Insta Capital"})

      {:ok, view, _html} = live(conn, ~p"/invoices?q=Insta")

      assert has_element?(view, "#invoice-#{second.id}")
      refute has_element?(view, "#invoice-#{first.id}")
    end

    test "a status carried in the URL is applied too", %{conn: conn} do
      invoice = create_invoice()

      {:ok, view, _html} = live(conn, ~p"/invoices?status=Draft")

      assert has_element?(view, "#invoice-#{invoice.id}")
    end

    # An unknown status falls back rather than emptying the table.
    test "an unknown status in the URL falls back rather than emptying the list", %{conn: conn} do
      invoice = create_invoice()

      {:ok, view, html} = live(conn, ~p"/invoices?status=Embezzled")

      assert has_element?(view, "#invoice-#{invoice.id}")
      assert html =~ "All Status"
    end

    test "deleting an invoice moves it to the Bin", %{conn: conn} do
      invoice = create_invoice()
      other = create_invoice(%{"client_name" => "Northwind Traders"})

      {:ok, view, _html} = live(conn, ~p"/invoices")

      # The confirmation says where it is going, not that it is gone for good.
      assert has_element?(view, ~s|#invoice-delete-#{invoice.id}[data-confirm*="Bin"]|)

      # A button in the row's actions, not an entry in the row's menu.
      assert has_element?(view, "#invoice-#{invoice.id} button#invoice-delete-#{invoice.id}")
      refute has_element?(view, "#invoice-#{invoice.id} ul #invoice-delete-#{invoice.id}")

      view |> element("#invoice-delete-#{invoice.id}") |> render_click()

      refute has_element?(view, "#invoice-#{invoice.id}")
      assert has_element?(view, "#invoice-#{other.id}")
      assert has_element?(view, "#flash-info", "moved to the Bin")

      # Off the list, not out of the database.
      assert Invoices.get_invoice(invoice.id) == nil
      assert Invoices.get_deleted_invoice(invoice.id).invoice_number == invoice.invoice_number

      {:ok, bin, _html} = live(conn, ~p"/bin")
      assert has_element?(bin, "#bin-invoice-#{invoice.id}", invoice.invoice_number)
    end

    test "a binned invoice can no longer be opened", %{conn: conn} do
      invoice = create_invoice()
      {:ok, _binned} = Invoices.delete_invoice(invoice)

      {:ok, view, _html} = live(conn, ~p"/invoices")
      refute has_element?(view, "#invoice-#{invoice.id}")

      assert {:error, {kind, %{to: "/invoices"}}} = live(conn, ~p"/invoices/#{invoice.id}")
      assert kind in [:redirect, :live_redirect]
    end
  end

  describe "rows that fit the screen" do
    defp row_count(view) do
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("tbody tr") |> Enum.count()
    end

    setup do
      for _ <- 1..12, do: create_invoice()
      :ok
    end

    test "the pager's measured fit replaces the default page size", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      assert row_count(view) == 10
      refute has_element?(view, ~s(button[aria-label="Next page"][disabled]))

      view |> element("#pagination") |> render_hook("fit_rows", %{"rows" => 15})

      assert row_count(view) == 12
      assert has_element?(view, ~s(button[aria-label="Next page"][disabled]))
    end

    test "a short screen still gets a sensible page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#pagination") |> render_hook("fit_rows", %{"rows" => 1})

      assert row_count(view) == 5
    end

    test "keeps the row that was at the top of the page on screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")
      render_click(view, "paginate", %{"page" => "2"})

      view |> element("#pagination") |> render_hook("fit_rows", %{"rows" => 5})

      # Rows 11 and 12 were on page 2 of 10; at 5 a page they are on page 3.
      assert has_element?(view, ~s(span[aria-current="page"]), "3")
      assert row_count(view) == 2
    end

    test "ignores a value that isn't a number", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices")

      view |> element("#pagination") |> render_hook("fit_rows", %{"rows" => "lots"})

      assert row_count(view) == 10
    end
  end
end
