defmodule QuantumBillingWeb.ReportsControllerTest do
  use QuantumBillingWeb.ConnCase, async: true

  alias QuantumBilling.Reports

  setup :register_and_log_in_user

  describe "GET /reports/export" do
    test "downloads a CSV attachment", %{conn: conn} do
      conn = get(conn, ~p"/reports/export")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".csv"
    end

    test "starts with a header row", %{conn: conn} do
      body = conn |> get(~p"/reports/export") |> response(200)

      assert [header | _rest] = String.split(body, "\r\n")
      assert header == "Tax Type,Taxable Value,CGST,SGST,IGST,Total Tax"
    end

    test "totals match what the page shows", %{conn: conn} do
      body = conn |> get(~p"/reports/export?#{[date_range: "This Year"]}") |> response(200)

      expected =
        Reports.invoices()
        |> Reports.filter(%{date_range: "This Year"})
        |> Reports.tax_summary()
        |> Enum.find(& &1.total?)

      total_line = body |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "Total,"))

      assert total_line =~ :erlang.float_to_binary(expected.total_tax * 1.0, decimals: 2)
    end

    # An export that actually differs per filter needs rows to filter; that
    # assertion returns with the invoices table. What is checkable now is that
    # every filter parameter is accepted rather than crashing the download.
    test "accepts every filter parameter", %{conn: conn} do
      params = [
        date_range: "Last Month",
        report_type: "Tax Liability",
        client: "All Clients",
        status: "Cancelled",
        gstin: "27AAACP8542D1ZS"
      ]

      assert conn |> get(~p"/reports/export?#{params}") |> response(200) =~ "Tax Type,"
    end

    test "ignores an unknown range rather than failing", %{conn: conn} do
      assert conn |> get(~p"/reports/export?#{[date_range: "nonsense"]}") |> response(200) =~
               "Tax Type,"
    end

    test "names the file after the period", %{conn: conn} do
      conn = get(conn, ~p"/reports/export?#{[date_range: "Last Month"]}")

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "gst-tax-summary-last-month.csv"
    end

    test "an empty result still returns a header row", %{conn: conn} do
      body = conn |> get(~p"/reports/export?#{[gstin: "NOSUCHGSTIN"]}") |> response(200)

      assert body =~ "Tax Type,Taxable Value,CGST,SGST,IGST,Total Tax"
    end

    test "exports sales register when report_type is Sales Register", %{conn: conn} do
      conn =
        get(
          conn,
          ~p"/reports/export?#{[report_type: "Sales Register", date_range: "This Month"]}"
        )

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "gst-sales-register-this-month.csv"

      body = response(conn, 200)

      assert body =~
               "Date,Invoice Number,Client,GSTIN,Status,Tax Type,Taxable Value,CGST,SGST,IGST,Cess,Total Tax,Grand Total"
    end

    test "requires authentication" do
      conn = get(build_conn(), ~p"/reports/export")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
