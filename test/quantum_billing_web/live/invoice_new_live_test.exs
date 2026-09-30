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
          "pan" => "AABCA1234A",
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

  # The client from the bug report: a consumer-facing business with no GSTIN,
  # so there is genuinely nothing to copy.
  defp unregistered_client do
    {:ok, client} =
      Clients.create_client(%{
        "client_type" => "Unregistered",
        "name" => "Apex Retail Solutions",
        "phone" => "9876500000",
        "billing_line1" => "14 MG Road",
        "billing_city" => "Bengaluru",
        "billing_state" => "Karnataka (29)",
        "billing_pin" => "560001"
      })

    client
  end

  # An input in the client block, optionally with the value it must hold. By
  # name, so the assertion is about one field rather than the whole page.
  defp client_field(field), do: ~s(#invoice-form [name="invoice[#{field}]"])
  defp client_field(field, value), do: client_field(field) <> ~s([value="#{value}"])

  # Matches only when the input holds something: an untouched input has no
  # value attribute at all, a cleared one has an empty one.
  defp filled_field(field), do: client_field(field) <> ~s|[value]:not([value=""])|

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
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#invoice-items tr[id^=invoice-item-]")
      |> Enum.count()
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

  describe "the tax on a row" do
    # The rows from the bug report: 12 × 3,000 and 23 × 30, both at 18%. The
    # Amount column showed 36,000 and 690 whatever rate was chosen.
    defp taxed_line(description, quantity, rate, tax_rate, position) do
      %{
        "description" => description,
        "quantity" => quantity,
        "unit" => "Nos",
        "rate" => rate,
        "tax_rate" => tax_rate,
        "position" => to_string(position)
      }
    end

    defp with_lines(lines) do
      items =
        lines |> Enum.with_index() |> Map.new(fn {line, index} -> {to_string(index), line} end)

      %{"invoice" => valid_params(%{"items" => items, "items_sort" => Map.keys(items)})}
    end

    test "is worked out in the row, and the rows add up to the total", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      render_change(
        view,
        "validate",
        with_lines([
          taxed_line("Consulting", "12", "3000", "18", 0),
          taxed_line("Cables", "23", "30", "18", 1)
        ])
      )

      assert has_element?(view, "#invoice-item-amount-0", "₹42,480.00")
      assert has_element?(view, "#invoice-item-tax-0", "₹6,480.00")

      assert has_element?(view, "#invoice-item-amount-1", "₹814.00")
      assert has_element?(view, "#invoice-item-tax-1", "₹124.00")

      # 42,480 + 814: what the rows show is what the invoice comes to.
      assert has_element?(view, "#invoice-summary-grand-total", "₹ 43,294.00")
    end

    test "follows the rate chosen for that row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      for {tax_rate, amount, tax} <- [
            {"5", "₹37,800.00", "₹1,800.00"},
            {"28", "₹46,080.00", "₹10,080.00"},
            {"0", "₹36,000.00", "₹0.00"}
          ] do
        render_change(
          view,
          "validate",
          with_lines([taxed_line("Consulting", "12", "3000", tax_rate, 0)])
        )

        assert has_element?(view, "#invoice-item-amount-0", amount)
        assert has_element?(view, "#invoice-item-tax-0", tax)

        assert has_element?(
                 view,
                 "#invoice-summary-grand-total",
                 String.replace(amount, "₹", "₹ ")
               )
      end
    end

    test "each row is taxed at its own rate", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      render_change(
        view,
        "validate",
        with_lines([
          taxed_line("Services", "1", "1000", "18", 0),
          taxed_line("Goods", "1", "1000", "5", 1)
        ])
      )

      assert has_element?(view, "#invoice-item-amount-0", "₹1,180.00")
      assert has_element?(view, "#invoice-item-amount-1", "₹1,050.00")
      assert has_element?(view, "#invoice-summary-grand-total", "₹ 2,230.00")
    end

    # A half-typed row: the rate box is still empty, or holds something that
    # is not a whole number of rupees.
    test "a row with no rate yet comes to nothing rather than crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      render_change(view, "validate", with_lines([taxed_line("Consulting", "12", "", "18", 0)]))

      assert has_element?(view, "#invoice-item-amount-0", "₹0.00")
      assert has_element?(view, "#invoice-item-tax-0", "₹0.00")

      render_change(
        view,
        "validate",
        with_lines([taxed_line("Consulting", "12", "abc", "18", 0)])
      )

      assert has_element?(view, "#invoice-item-amount-0", "₹0.00")
      assert has_element?(view, "#invoice-item-tax-0", "₹0.00")
    end
  end

  describe "editing items" do
    # The edit form is where rows used to multiply: a stored row that comes back
    # without its id is read as a new one, and the stored one is kept beside it.
    # These go through form/3 on purpose, so what is submitted is what the page
    # actually rendered — hidden ids included.
    setup do
      {:ok, invoice} =
        Invoices.create_invoice(
          valid_params(%{
            "items" => %{"0" => line("First", "1000", 0), "1" => line("Second", "2000", 1)}
          })
        )

      %{invoice: invoice}
    end

    defp stored_items(invoice) do
      Invoices.get_invoice!(invoice.id).items
    end

    # By name rather than by id: an item input's id follows the row it belongs
    # to, so it survives reordering, while the name says where the row is now.
    defp item_input(index, field) do
      ~s(#invoice-item-#{index} [name="invoice[items][#{index}][#{field}]"])
    end

    defp item_input(index, field, value) do
      item_input(index, field) <> ~s([value="#{value}"])
    end

    test "every stored row carries its id", %{conn: conn, invoice: invoice} do
      {:ok, view, html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      assert rows(html) == 2

      for {item, index} <- Enum.with_index(invoice.items) do
        assert has_element?(
                 view,
                 ~s(#invoice-item-#{index} input[type="hidden"][name="invoice[items][#{index}][id]"][value="#{item.id}"])
               )
      end
    end

    test "a change does not duplicate the stored rows", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      once = view |> form("#invoice-form") |> render_change()
      assert rows(once) == 2

      twice =
        view
        |> form("#invoice-form", %{"invoice" => %{"items" => %{"0" => %{"rate" => "1500"}}}})
        |> render_change()

      assert rows(twice) == 2
      assert has_element?(view, item_input(0, "rate", "1500"))
      assert has_element?(view, item_input(1, "description", "Second"))
    end

    # Through form/3, so this is the <select> the page rendered being changed.
    test "a stored row shows its tax, and follows a change of rate", %{
      conn: conn,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      assert has_element?(view, "#invoice-item-amount-0", "₹1,180.00")
      assert has_element?(view, "#invoice-item-tax-0", "₹180.00")
      assert has_element?(view, "#invoice-summary-grand-total", "₹ 3,540.00")

      view
      |> form("#invoice-form", %{"invoice" => %{"items" => %{"0" => %{"tax_rate" => "5"}}}})
      |> render_change()

      assert has_element?(view, "#invoice-item-amount-0", "₹1,050.00")
      assert has_element?(view, "#invoice-item-tax-0", "₹50.00")
      # The other row is untouched: 1,050 + 2,360.
      assert has_element?(view, "#invoice-item-amount-1", "₹2,360.00")
      assert has_element?(view, "#invoice-summary-grand-total", "₹ 3,410.00")
    end

    test "Add New Item appends exactly one blank row", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      added =
        view
        |> form("#invoice-form")
        |> render_change(%{"invoice" => %{"items_sort" => ["0", "1", "new"]}})

      assert rows(added) == 3
      assert has_element?(view, item_input(0, "description", "First"))
      assert has_element?(view, item_input(1, "description", "Second"))
      assert has_element?(view, item_input(2, "description"))
      refute has_element?(view, item_input(2, "description") <> "[value]")

      # Typing in the new row must not bring another one with it.
      typed =
        view
        |> form("#invoice-form", %{
          "invoice" => %{"items" => %{"2" => %{"description" => "Third", "rate" => "3000"}}}
        })
        |> render_change()

      assert rows(typed) == 3
    end

    test "the bin button removes its row and it stays removed", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      assert has_element?(view, "#invoice-item-remove-0")

      removed =
        view
        |> form("#invoice-form")
        |> render_change(%{"invoice" => %{"items_drop" => ["0"]}})

      assert rows(removed) == 1
      assert has_element?(view, item_input(0, "description", "Second"))
      refute has_element?(view, "#invoice-item-1")

      again = view |> form("#invoice-form") |> render_change()
      assert rows(again) == 1
    end

    test "saving after a removal deletes that item only", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")
      [_first, second] = invoice.items

      view
      |> form("#invoice-form")
      |> render_change(%{"invoice" => %{"items_drop" => ["0"]}})

      view |> form("#invoice-form") |> render_submit()

      assert [kept] = stored_items(invoice)
      assert kept.id == second.id
      assert kept.description == "Second"
    end

    test "saving after an addition keeps the stored rows and adds one", %{
      conn: conn,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      view
      |> form("#invoice-form")
      |> render_change(%{"invoice" => %{"items_sort" => ["0", "1", "new"]}})

      view
      |> form("#invoice-form", %{
        "invoice" => %{"items" => %{"2" => %{"description" => "Third", "rate" => "3000"}}}
      })
      |> render_submit()

      items = stored_items(invoice)

      assert Enum.map(items, & &1.description) == ["First", "Second", "Third"]
      # Updated in place, not deleted and re-created.
      assert Enum.map(Enum.take(items, 2), & &1.id) == Enum.map(invoice.items, & &1.id)
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

    # The V2V fixture has a GSTIN and no PAN of its own — which is the common
    # case, since the client form does not ask for one.
    test "the PAN is read out of the client's GSTIN", %{conn: conn} do
      client = create_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      render_change(view, "validate", %{
        "invoice" => valid_params(%{"client_id" => to_string(client.id), "client_gstin" => ""})
      })

      assert has_element?(view, client_field("client_gstin", "27AAACP8542D1ZS"))
      assert has_element?(view, client_field("client_pan", "AAACP8542D"))
    end

    test "typing a GSTIN fills an empty PAN", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view
      |> form("#invoice-form", %{"invoice" => %{"client_gstin" => "29aabcu9603r1zm"}})
      |> render_change()

      assert has_element?(view, client_field("client_pan", "AABCU9603R"))
      assert has_element?(view, filled_field("client_pan"))
    end

    test "a PAN that was typed is left alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view
      |> form("#invoice-form", %{
        "invoice" => %{"client_gstin" => "29AABCU9603R1ZM", "client_pan" => "ZZZZZ9999Z"}
      })
      |> render_change()

      assert has_element?(view, client_field("client_pan", "ZZZZZ9999Z"))
    end

    test "half a GSTIN fills nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view
      |> form("#invoice-form", %{"invoice" => %{"client_gstin" => "29AABCU96"}})
      |> render_change()

      refute has_element?(view, filled_field("client_pan"))
    end

    test "typing a client's exact name fetches its details", %{conn: conn} do
      client = create_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view
      |> form("#invoice-form", %{"invoice" => %{"client_name" => "  v2v technologies "}})
      |> render_change(%{"_target" => ["invoice", "client_name"]})

      assert has_element?(view, client_field("client_name", "V2V Technologies"))
      assert has_element?(view, client_field("client_gstin", "27AAACP8542D1ZS"))
      assert has_element?(view, client_field("client_pan", "AAACP8542D"))
      assert has_element?(view, client_field("client_email", "billing@v2v.in"))

      assert has_element?(
               view,
               ~s(select[name="invoice[client_id]"] option[value="#{client.id}"][selected])
             )
    end

    test "part of a client's name fetches nothing", %{conn: conn} do
      _client = create_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view
      |> form("#invoice-form", %{"invoice" => %{"client_name" => "V2V Tech"}})
      |> render_change(%{"_target" => ["invoice", "client_name"]})

      assert has_element?(view, client_field("client_name", "V2V Tech"))
      refute has_element?(view, filled_field("client_gstin"))
      refute has_element?(view, ~s(select[name="invoice[client_id]"] option[value][selected]))
    end

    test "a name only counts while the name box is what changed", %{conn: conn} do
      _client = create_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      # Same text, but the change came from another input: a one-off invoice
      # for somebody who merely shares a client's name stays a one-off.
      view
      |> form("#invoice-form", %{"invoice" => %{"client_name" => "V2V Technologies"}})
      |> render_change(%{"_target" => ["invoice", "notes"]})

      refute has_element?(view, filled_field("client_gstin"))
    end

    test "says so when the chosen client has no GSTIN on file", %{conn: conn} do
      client = unregistered_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      refute has_element?(view, "#invoice-form p", "No GSTIN on file")

      view
      |> form("#invoice-form", %{"invoice" => %{"client_id" => to_string(client.id)}})
      |> render_change()

      assert has_element?(view, client_field("client_name", "Apex Retail Solutions"))

      assert has_element?(
               view,
               "#invoice-form p",
               "No GSTIN on file for this client (Unregistered)."
             )

      # The note explains an empty box; once something is typed it is in the way.
      view
      |> form("#invoice-form", %{"invoice" => %{"client_gstin" => "29AABCU9603R1ZM"}})
      |> render_change()

      refute has_element?(view, "#invoice-form p", "No GSTIN on file")
    end

    test "the note goes when the client is deselected", %{conn: conn} do
      client = unregistered_client()
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      view
      |> form("#invoice-form", %{"invoice" => %{"client_id" => to_string(client.id)}})
      |> render_change()

      view |> form("#invoice-form", %{"invoice" => %{"client_id" => ""}}) |> render_change()

      refute has_element?(view, "#invoice-form p", "No GSTIN on file")
    end
  end

  describe "client details on the edit page" do
    test "fills in a GSTIN and PAN the invoice was saved without", %{conn: conn} do
      client = create_client()

      {:ok, invoice} =
        Invoices.create_invoice(
          valid_params(%{"client_id" => to_string(client.id), "client_gstin" => ""})
        )

      assert invoice.client_gstin in [nil, ""]

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      assert has_element?(view, client_field("client_gstin", "27AAACP8542D1ZS"))
      assert has_element?(view, client_field("client_pan", "AAACP8542D"))

      # Offered, not written: opening the page changes nothing.
      assert Invoices.get_invoice!(invoice.id).client_gstin in [nil, ""]

      view |> form("#invoice-form") |> render_submit()

      saved = Invoices.get_invoice!(invoice.id)
      assert saved.client_gstin == "27AAACP8542D1ZS"
      assert saved.client_pan == "AAACP8542D"
    end

    test "fills in the PAN of an invoice that has only a GSTIN", %{conn: conn} do
      {:ok, invoice} = Invoices.create_invoice(valid_params())
      assert invoice.client_pan in [nil, ""]

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      assert has_element?(view, client_field("client_pan", "AAACP8542D"))
    end

    test "leaves stored values alone", %{conn: conn} do
      client = create_client()

      {:ok, invoice} =
        Invoices.create_invoice(
          valid_params(%{
            "client_id" => to_string(client.id),
            "client_gstin" => "29AABCU9603R1ZM",
            "client_pan" => "AABCU9603R"
          })
        )

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      assert has_element?(view, client_field("client_gstin", "29AABCU9603R1ZM"))
      assert has_element?(view, client_field("client_pan", "AABCU9603R"))
    end

    test "explains an empty GSTIN for a client that has none", %{conn: conn} do
      client = unregistered_client()

      {:ok, invoice} =
        Invoices.create_invoice(
          valid_params(%{
            "client_id" => to_string(client.id),
            "client_name" => client.name,
            "client_gstin" => ""
          })
        )

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      assert has_element?(
               view,
               "#invoice-form p",
               "No GSTIN on file for this client (Unregistered)."
             )

      refute has_element?(view, filled_field("client_pan"))
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
