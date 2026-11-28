defmodule QuantumBillingWeb.BusinessLocalDatesTest do
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Compliance
  alias QuantumBilling.Compliance.Task
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo
  alias QuantumBilling.Reports
  alias QuantumBilling.Settings

  @now ~U[2026-11-30 19:30:00Z]
  @today ~D[2026-12-01]

  setup :register_and_log_in_user

  setup do
    previous_clock = Application.fetch_env(:quantum_billing, :compliance_clock)
    Application.put_env(:quantum_billing, :compliance_clock, fn -> @now end)

    on_exit(fn ->
      case previous_clock do
        {:ok, clock} -> Application.put_env(:quantum_billing, :compliance_clock, clock)
        :error -> Application.delete_env(:quantum_billing, :compliance_clock)
      end
    end)
  end

  test "the new invoice uses the local day for its invoice and due dates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    assert has_element?(view, ~s(input[name="invoice[invoice_date]"][value="2026-12-01"]))
    assert has_element?(view, ~s(input[name="invoice[due_date]"][value="2026-12-31"]))
  end

  test "the dashboard and invoice queries use December while UTC is still in November",
       %{conn: conn} do
    insert_invoice("INV-NOV-A", ~D[2026-11-16])
    insert_invoice("INV-NOV-B", ~D[2026-11-30])
    insert_invoice("INV-DEC-A", @today)

    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "1 this month"
    assert has_element?(view, "#dashboard-tax-trend-sweep")
    assert html =~ ~r/>\s*Dec\s*<\/span>/
    assert %{count: 1} = Invoices.month_totals()
    assert %{count: 2} = Invoices.month_totals(~D[2026-11-30])
    assert [%{label: "Dec", cgst_sgst: 1_800}] = Invoices.monthly_tax_split(1)
  end

  test "reports use the local year at midnight in January" do
    Application.put_env(:quantum_billing, :compliance_clock, fn -> ~U[2026-12-31 19:30:00Z] end)

    insert_invoice("INV-OLD-YEAR", ~D[2026-12-31])
    insert_invoice("INV-NEW-YEAR", ~D[2027-01-01])

    assert Reports.range_bounds("This Year") == {~D[2027-01-01], ~D[2027-12-31]}
    assert [%{value: 11_800}] = Reports.top_client_totals(Reports.default_filters())
  end

  test "the Filed on picker allows the same local day as filing validation", %{conn: conn} do
    {:ok, org} =
      Settings.update_section(
        Settings.get_organization(),
        %{"gstin" => "27AABCA1234A1Z5", "company_name" => "Northwind Supply Co"},
        :general
      )

    obligation = @today |> Compliance.tracked_obligations(org) |> Enum.min_by(& &1.due_date, Date)
    {:ok, view, _html} = live(conn, ~p"/compliance")

    view
    |> element("#view-obligation-#{obligation.type}-#{obligation.due_date}")
    |> render_click()

    view |> element("#mark-filed-button") |> render_click()

    assert has_element?(
             view,
             ~s(#filing-form input[type="date"][max="2026-12-01"][value="2026-12-01"])
           )

    view
    |> form("#filing-form", filing: %{filed_on: "2026-12-01"})
    |> render_submit()

    assert has_element?(view, "#obligation-detail-status", "Filed")
  end

  test "compliance marks a task due on the previous local day as overdue", %{conn: conn} do
    task = Repo.insert!(%Task{title: "Renew trade licence", due_date: ~D[2026-11-30]})
    {:ok, view, _html} = live(conn, ~p"/compliance")

    assert has_element?(view, "#task-#{task.id}", "Overdue")
    assert [%{days_until: -1}] = Compliance.upcoming([Compliance.task_row(task, @today)])
  end

  test "a new recurring profile starts on the local day", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recurring")
    render_click(view, "toggle_modal")

    assert has_element?(view, ~s(#recurring-profile-form input[type="date"][value="2026-12-01"]))
  end

  test "the Bin compares deletion timestamps on the business's calendar", %{conn: conn} do
    today = insert_invoice("INV-TODAY", ~D[2026-11-30], ~U[2026-11-30 19:00:00Z])
    yesterday = insert_invoice("INV-YEST", ~D[2026-11-30], ~U[2026-11-30 17:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/bin")

    assert has_element?(view, "#bin-invoice-#{today.id}", "Deleted today")
    assert has_element?(view, "#bin-invoice-#{yesterday.id}", "Deleted yesterday")
  end

  defp insert_invoice(number, invoice_date, deleted_at \\ nil) do
    Repo.insert!(%Invoice{
      invoice_number: number,
      invoice_date: invoice_date,
      client_name: "Acme Corp",
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      taxable_value: 10_000,
      cgst_amount: 900,
      sgst_amount: 900,
      grand_total: 11_800,
      deleted_at: deleted_at
    })
  end
end
