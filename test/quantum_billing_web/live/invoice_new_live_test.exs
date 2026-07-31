defmodule QuantumBillingWeb.InvoiceNewLiveTest do
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  setup do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "ABC Solutions Private Limited",
          "gstin" => "27AABCA1234A1Z5",
          "state" => "Maharashtra (27)"
        },
        :general
      )

    :ok
  end

  defp create_client do
    {:ok, client} =
      Clients.create_client(%{
        "client_type" => "Registered Business",
        "name" => "V2V Technologies",
        "gstin" => "27AAACP8542D1ZS",
        "email" => "billing@v2v.in",
        "phone" => "9876543210",
        "billing_line1" => "123 Business Park",
        "billing_line2" => "Andheri East",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400093"
      })

    client
  end

  defp valid_params(over \\ %{}) do
    Map.merge(
      %{
        "invoice_type" => "Tax Invoice",
        "invoice_date" => "2024-05-28",
        "due_date" => "2024-06-12",
        "payment_terms" => "Net 15 Days",
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "V2V Technologies",
        "client_gstin" => "27AAACP8542D1ZS",
        "items" => %{
          "0" => %{
            "description" => "Web Development Services",
            "hsn_sac" => "998313",
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
  end

  describe "page" do
    test "renders every numbered section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invoices/new")

      assert html =~ "Create New GST Invoice"
      assert html =~ "Invoice Details"
      assert html =~ "Client Details"
      assert html =~ "Item Details"
      assert html =~ "Additional Information"
      assert html =~ "Invoice Summary"
      assert html =~ "From (Your Company)"
    end

    test "shows the number that will be assigned", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invoices/new")

      assert html =~ "INV-0001"
      assert html =~ "Assigned on save"
    end

    test "shows the company details from Settings", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invoices/new")

      assert html =~ "ABC Solutions Private Limited"
      assert html =~ "27AABCA1234A1Z5"
    end

    test "the attachment control says it needs storage", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invoices/new")

      assert html =~ "Needs file storage"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/invoices/new")
    end
  end

  describe "the live summary" do
    test "starts at zero", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invoices/new")

      assert html =~ "Grand Total"
      assert html =~ "Rupees Zero Only"
    end

    test "recomputes as items are typed, without saving anything", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      html = view |> form("#invoice-form", %{"invoice" => valid_params()}) |> render_change()

      assert html =~ "₹ 50,000.00"
      # 18% of 50,000, split evenly.
      assert html =~ "₹ 4,500.00"
      assert html =~ "₹ 59,000.00"
      assert html =~ "Rupees Fifty Nine Thousand Only"

      assert Invoices.list_invoices() == []
    end

    test "switching to another state moves the tax to IGST", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      intra = view |> form("#invoice-form", %{"invoice" => valid_params()}) |> render_change()
      assert intra =~ "Same state as your business"

      inter =
        view
        |> form("#invoice-form", %{
          "invoice" => valid_params(%{"place_of_supply" => "Karnataka (29)"})
        })
        |> render_change()

      assert inter =~ "Different state from your business"
      assert inter =~ "₹ 9,000.00"
    end
  end

  describe "line items" do
    # These drive the change handler directly rather than through form/3.
    # form/3 checks every value against the inputs currently rendered, which
    # cannot express "add a row that does not exist yet" — the browser sends
    # exactly these params, so this is what the handler has to cope with.
    defp line(description, rate, position) do
      %{
        "description" => description,
        "quantity" => "1",
        "unit" => "Nos",
        "rate" => rate,
        "tax_rate" => "18",
        "position" => to_string(position)
      }
    end

    defp rows(html) do
      html |> String.split(~s(name="invoice[items_sort][]")) |> length() |> Kernel.-(2)
    end

    test "starts with one blank row", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invoices/new")

      assert rows(html) == 1
    end

    test "a row can be added", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      added =
        render_change(view, "validate", %{
          "invoice" =>
            valid_params(%{
              "items_sort" => ["0", "new"],
              "items" => %{"0" => line("First", "1000", 0)}
            })
        })

      assert rows(added) == 2
    end

    test "a row can be removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      two_rows = %{
        "items" => %{"0" => line("First", "1000", 0), "1" => line("Second", "2000", 1)},
        "items_sort" => ["0", "1"]
      }

      two = render_change(view, "validate", %{"invoice" => valid_params(two_rows)})
      assert rows(two) == 2
      assert two =~ "Second"

      one =
        render_change(view, "validate", %{
          "invoice" => valid_params(Map.put(two_rows, "items_drop", ["1"]))
        })

      assert rows(one) == 1
      refute one =~ "Second"
    end

    test "the summary sums every row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      html =
        render_change(view, "validate", %{
          "invoice" =>
            valid_params(%{
              "items" => %{"0" => line("First", "50000", 0), "1" => line("Second", "10000", 1)},
              "items_sort" => ["0", "1"]
            })
        })

      # 60,000 taxable, 10,800 tax split evenly, 70,800 total — the screenshot.
      assert html =~ "₹ 60,000.00"
      assert html =~ "₹ 5,400.00"
      assert html =~ "₹ 70,800.00"
      assert html =~ "Rupees Seventy Thousand Eight Hundred Only"
    end
  end

  describe "client autofill" do
    test "picking a client copies its details across", %{conn: conn} do
      client = create_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      html =
        render_change(view, "validate", %{
          "invoice" =>
            valid_params(%{
              "client_id" => to_string(client.id),
              "client_name" => "",
              "client_gstin" => ""
            })
        })

      assert html =~ "V2V Technologies"
      assert html =~ "27AAACP8542D1ZS"
      assert html =~ "billing@v2v.in"
      assert html =~ "123 Business Park"
    end

    test "an edit to a copied field is not overwritten by the next keystroke", %{conn: conn} do
      client = create_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      # First change selects the client and copies its details in.
      render_change(view, "validate", %{
        "invoice" => valid_params(%{"client_id" => to_string(client.id)})
      })

      # Second change keeps the same client but renames it by hand. The copy
      # must not run again and undo that edit.
      html =
        render_change(view, "validate", %{
          "invoice" =>
            valid_params(%{
              "client_id" => to_string(client.id),
              "client_name" => "V2V Technologies (Head Office)"
            })
        })

      assert html =~ "V2V Technologies (Head Office)"
    end
  end

  describe "saving" do
    test "creates the invoice and lands on the document", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      assert {:error, {:live_redirect, %{to: path}}} =
               view |> form("#invoice-form", %{"invoice" => valid_params()}) |> render_submit()

      assert [invoice] = Invoices.list_invoices()
      assert path == "/invoices/#{invoice.id}"
      assert invoice.number == "INV-0001"
      assert invoice.status == "Draft"
      assert invoice.amount == 59_000
    end

    test "stores the company snapshot", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view |> form("#invoice-form", %{"invoice" => valid_params()}) |> render_submit()

      [row] = Invoices.list_invoices()
      assert Invoices.get_invoice!(row.id).company_name == "ABC Solutions Private Limited"
    end

    test "an invoice with no items is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      html =
        view
        |> form("#invoice-form", %{
          "invoice" => valid_params(%{"items" => %{}, "items_drop" => ["0"]})
        })
        |> render_submit()

      assert html =~ "add at least one item"
      assert Invoices.list_invoices() == []
    end

    test "an item with no description is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      params =
        valid_params(%{
          "items" => %{
            "0" => %{
              "description" => "",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "1000",
              "tax_rate" => "18",
              "position" => "0"
            }
          }
        })

      view |> form("#invoice-form", %{"invoice" => params}) |> render_submit()

      assert Invoices.list_invoices() == []
    end

    test "a due date before the invoice date is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      html =
        view
        |> form("#invoice-form", %{
          "invoice" => valid_params(%{"payment_terms" => "Custom", "due_date" => "2024-05-01"})
        })
        |> render_submit()

      assert html =~ "cannot be before the invoice date"
      assert Invoices.list_invoices() == []
    end
  end

  describe "payment terms" do
    test "choosing a term sets the due date", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      html =
        view
        |> form("#invoice-form", %{
          "invoice" =>
            valid_params(%{
              "invoice_date" => "2024-05-28",
              "payment_terms" => "Net 15 Days",
              "due_date" => "2024-01-01"
            })
        })
        |> render_change()

      # 28 May + 15 days.
      assert html =~ "2024-06-12"
    end

    test "Custom leaves the due date alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      html =
        view
        |> form("#invoice-form", %{
          "invoice" =>
            valid_params(%{
              "invoice_date" => "2024-05-28",
              "payment_terms" => "Custom",
              "due_date" => "2024-07-15"
            })
        })
        |> render_change()

      assert html =~ "2024-07-15"
    end
  end
end
