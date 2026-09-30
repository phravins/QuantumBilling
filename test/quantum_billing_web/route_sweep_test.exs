defmodule QuantumBillingWeb.RouteSweepTest do
  @moduledoc """
  Walks every page in the application with real records behind it.

  Most pages in this application were written before there was anything to put
  on them, and several of them only ever ran empty: the e-way bill list
  rendered fields no schema had and raised `KeyError` the moment one genuine
  bill existed, and the GSTR-1 download raised on the first line item it was
  asked to summarise. Both were reachable in a browser and neither had a test
  that gave it a row to render.

  So this is deliberately not a unit test. It seeds one of everything — a
  client, an intra-state invoice with items, an inter-state one, a credit
  note, an e-way bill, a recurring profile, an audit entry, a template — and
  then asks for every route, asserting only that the application answers
  rather than falling over. It is the cheapest guard against a page that works
  until it has data.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Recurring
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates

  setup :register_and_log_in_user

  setup do
    {:ok, _organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "Quantum Billing Tech",
          "gstin" => "27AABCQ9999Q1Z5",
          "pan" => "AABCQ9999Q",
          "state" => "Maharashtra (27)",
          # The seller's own address is part of an e-invoice, so the XML route
          # cannot be exercised without it.
          "address" => "Unit 401, Tech Park",
          "city" => "Mumbai",
          "pincode" => "400051"
        },
        :general
      )

    {:ok, client} =
      Clients.create_client(%{
        "client_type" => "Registered Business",
        "name" => "Acme Traders",
        "gstin" => "27AABCA1234A1Z5",
        "phone" => "9876543210",
        "email" => "billing@acme.test",
        "billing_line1" => "1 Main Street",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400001"
      })

    {:ok, invoice} = invoice_for(client, "Maharashtra (27)", "998313", "18")
    {:ok, interstate} = invoice_for(client, "Karnataka (29)", "1001", "5")

    {:ok, _note} =
      CreditNotes.create_credit_note_for_invoice(invoice, %{
        "note_type" => "Credit",
        "grand_total" => Decimal.new("1000")
      })

    {:ok, bill} =
      EWayBills.generate_e_way_bill(interstate, %{
        "distance_km" => "200",
        "vehicle_number" => "MH12AB1234"
      })

    {:ok, _profile} =
      Recurring.create_profile(%{
        "client_id" => client.id,
        "title" => "Monthly retainer",
        "frequency" => "Monthly",
        "next_run_date" => Date.to_iso8601(Date.utc_today())
      })

    Audit.log_event(:create_invoice, "Invoice", invoice.id, details: %{by: "route sweep"})
    template = Templates.ensure_default()

    %{
      client: client,
      invoice: Repo.get!(Invoice, invoice.id),
      interstate: interstate,
      bill: bill,
      template: template
    }
  end

  defp invoice_for(client, place_of_supply, hsn, rate) do
    Invoices.create_invoice(%{
      "client_id" => client.id,
      "client_name" => client.name,
      "client_gstin" => client.gstin,
      "client_billing_address" => "1 Main Street, Mumbai",
      "client_city" => "Mumbai",
      "client_pincode" => "400001",
      "client_state" => "Maharashtra (27)",
      "invoice_date" => Date.to_iso8601(Date.utc_today()),
      "place_of_supply" => place_of_supply,
      "items" => %{
        "0" => %{
          "description" => "Line one",
          "hsn_sac" => hsn,
          "quantity" => "2",
          "unit" => "Nos",
          "rate" => "5000",
          "tax_rate" => rate
        }
      }
    })
  end

  describe "every LiveView page, with records behind it" do
    test "renders", context do
      %{conn: conn, client: client, invoice: invoice, template: template} = context

      paths = [
        ~p"/",
        ~p"/dashboard",
        ~p"/invoices",
        ~p"/invoices/new",
        ~p"/invoices/#{invoice.id}",
        ~p"/invoices/#{invoice.id}/edit",
        ~p"/clients",
        ~p"/clients/new",
        ~p"/clients/#{client.id}",
        ~p"/clients/#{client.id}/edit",
        ~p"/e-way-bills",
        ~p"/e-way-bills/new",
        ~p"/hsn-finder",
        ~p"/reports",
        ~p"/compliance",
        ~p"/recurring",
        ~p"/bin",
        ~p"/settings",
        ~p"/settings/audit-logs",
        ~p"/invoice-templates/#{template.id}"
      ]

      for path <- paths do
        assert {:ok, _view, html} = live(conn, path), "#{path} did not mount"
        assert html =~ "<html", "#{path} rendered no document"
      end
    end

    test "every settings section renders", %{conn: conn} do
      for section <- ~w(general invoice tax e-way-bill smtp integrations security notifications) do
        assert {:ok, _view, _html} = live(conn, ~p"/settings/#{section}"),
               "settings/#{section} did not mount"
      end
    end
  end

  describe "every download and document route" do
    test "the printable invoice page answers", %{conn: conn, invoice: invoice} do
      body = conn |> get(~p"/invoices/#{invoice.id}/pdf") |> response(200)

      assert body =~ invoice.invoice_number
    end

    test "the PDF download either prints or says why it cannot", %{conn: conn, invoice: invoice} do
      conn = get(conn, ~p"/invoices/#{invoice.id}/pdf/download")

      case QuantumBillingWeb.InvoiceDoc.PDF.executable() do
        nil ->
          # No headless browser here. Sending the print page beats sending
          # something that is not a PDF, which is what the mail attachment
          # used to do.
          assert redirected_to(conn) == ~p"/invoices/#{invoice.id}/pdf"

        _binary ->
          assert <<"%PDF-", _rest::binary>> = response(conn, 200)
      end
    end

    # Both e-way bill row actions used to link at a filtered invoice list:
    # the form GST EWB-01 a driver must carry was nowhere in the application.
    # Addressed by the bill, not the invoice: an invoice can carry a cancelled
    # bill and its live replacement, and the two need separate URLs.
    test "the e-way bill document answers", context do
      %{conn: conn, interstate: interstate, bill: bill} = context

      body = conn |> get(~p"/e-way-bills/#{bill.id}/print") |> response(200)

      assert body =~ "Form GST EWB-01"
      assert body =~ interstate.invoice_number
      assert body =~ bill.ewb_number
    end

    test "the e-way bill PDF either prints or says why it cannot", context do
      %{conn: conn, bill: bill} = context

      conn = get(conn, ~p"/e-way-bills/#{bill.id}/print/download")

      case QuantumBillingWeb.InvoiceDoc.PDF.executable() do
        nil ->
          assert redirected_to(conn) == ~p"/e-way-bills/#{bill.id}/print"

        _binary ->
          assert <<"%PDF-", _rest::binary>> = response(conn, 200)
      end
    end

    test "the e-way bill export answers with the list as CSV", context do
      %{conn: conn, bill: bill, interstate: interstate} = context

      body = conn |> get(~p"/e-way-bills/export") |> response(200)

      # Not the GST tax summary the button used to hand back.
      assert body =~ "EWB Number,Document Number"
      assert body =~ bill.ewb_number
      assert body =~ interstate.invoice_number
    end

    test "the e-invoice XML route answers", %{conn: conn, invoice: invoice} do
      response = conn |> get(~p"/invoices/#{invoice.id}/e-invoice.xml") |> response(200)

      assert response =~ "<?xml"
      assert response =~ invoice.invoice_number
      assert response =~ "<Gstin>27AABCQ9999Q1Z5</Gstin>"
    end

    test "an invoice that cannot be filed is refused, not written wrong", context do
      %{conn: conn, invoice: invoice} = context

      # A seller with no address cannot file an e-invoice. Producing the
      # document anyway would be a tax record that is quietly wrong, which is
      # worse than one that was never produced.
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name" => "Quantum Billing Tech", "address" => nil, "city" => nil},
          :general
        )

      conn = get(conn, ~p"/invoices/#{invoice.id}/e-invoice.xml")

      assert redirected_to(conn) == ~p"/invoices/#{invoice.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not ready to report"
    end

    test "the report export answers for every report type", %{conn: conn} do
      for type <- QuantumBilling.Reports.report_types() do
        conn = get(conn, ~p"/reports/export?#{[report_type: type]}")

        assert response(conn, 200)
        assert response_content_type(conn, :csv)
      end
    end

    test "the GSTR-1 export answers for the period with invoices in it", %{conn: conn} do
      today = Date.utc_today()
      period = String.pad_leading(to_string(today.month), 2, "0") <> to_string(today.year)

      conn = get(conn, ~p"/reports/gstr1/export?#{[period: period]}")

      assert body = response(conn, 200)
      assert %{"fp" => ^period, "b2b" => [_ | _]} = Jason.decode!(body)
    end

    test "the backup download answers", %{conn: conn} do
      body = conn |> get(~p"/settings/backup/download") |> response(200)

      assert %{"version" => "2.1", "invoices" => [_ | _]} = Jason.decode!(body)
    end
  end

  describe "the public routes, without a session" do
    test "the invoice portal and its PDF answer for a real token", %{invoice: invoice} do
      assert {:ok, _view, html} = live(build_conn(), ~p"/pay/#{invoice.public_token}")
      assert html =~ invoice.invoice_number

      assert build_conn() |> get(~p"/pay/#{invoice.public_token}/pdf") |> response(200)
    end

    test "the legal pages answer" do
      assert {:ok, _view, _html} = live(build_conn(), ~p"/terms")
      assert {:ok, _view, _html} = live(build_conn(), ~p"/privacy")
    end

    test "an unknown token is a miss, not a crash" do
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(build_conn(), ~p"/pay/not-a-real-token")

      assert message =~ "Invalid or expired"
    end
  end
end
