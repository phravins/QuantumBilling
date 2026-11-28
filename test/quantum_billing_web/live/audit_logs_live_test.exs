defmodule QuantumBillingWeb.AuditLogsLiveTest do
  use QuantumBillingWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias QuantumBilling.AccountsFixtures
  alias QuantumBilling.ApiFixtures
  alias QuantumBilling.Audit

  setup :register_and_log_in_owner

  defp staff_member(name) do
    AccountsFixtures.user_fixture()
    |> Ecto.Changeset.change(full_name: name)
    |> QuantumBilling.Repo.update!()
  end

  test "lists who did what, with the record's name and no made-up address", %{conn: conn} do
    staff = staff_member("Meera Iyer")

    {:ok, log} =
      Audit.log_event(:invoice_updated, "Invoice", 42,
        user_id: staff.id,
        label: "INV-0042",
        changes: %{"notes" => %{"from" => "a", "to" => "b"}}
      )

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs")

    row = element(view, "#audit-row-#{log.id}")
    assert render(row) =~ "INV-0042"
    assert render(row) =~ "Meera Iyer"
    refute render(view) =~ "127.0.0.1"
    refute has_element?(view, "#audit-empty")
  end

  test "an API key's action names the key", %{conn: conn} do
    {_raw, key} = ApiFixtures.api_key_fixture(["invoices:write"], %{"name" => "Zapier sync"})

    {:ok, log} =
      Audit.log_event(:invoice_created, "Invoice", 7, api_key_id: key.id, label: "INV-0007")

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs")

    assert render(element(view, "#audit-row-#{log.id}")) =~ "Zapier sync"
  end

  test "filters by member, kind of activity and text, through the URL", %{conn: conn} do
    staff = staff_member("Arjun Rao")

    {:ok, by_staff} =
      Audit.log_event(:client_updated, "Client", 1, user_id: staff.id, label: "Acme Ltd")

    {:ok, by_system} = Audit.log_event(:invoice_created, "Invoice", 2, label: "INV-0002")

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs")
    assert has_element?(view, "#audit-row-#{by_staff.id}")
    assert has_element?(view, "#audit-row-#{by_system.id}")

    view |> element("#audit-filters") |> render_change(%{"who" => to_string(staff.id)})
    assert_patch(view, ~p"/settings/audit-logs?#{%{"who" => to_string(staff.id)}}")
    assert has_element?(view, "#audit-row-#{by_staff.id}")
    refute has_element?(view, "#audit-row-#{by_system.id}")

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs?category=Invoices")
    refute has_element?(view, "#audit-row-#{by_staff.id}")
    assert has_element?(view, "#audit-row-#{by_system.id}")

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs?q=acme")
    assert has_element?(view, "#audit-row-#{by_staff.id}")
    refute has_element?(view, "#audit-row-#{by_system.id}")
    assert has_element?(view, "#audit-clear-filters")
  end

  test "a date range with nothing in it shows the empty state", %{conn: conn} do
    {:ok, log} = Audit.log_event(:client_created, "Client", 3, label: "Old Co")

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs?from=2001-01-01&to=2001-01-31")

    refute has_element?(view, "#audit-row-#{log.id}")
    assert has_element?(view, "#audit-empty")
  end

  test "filters that make no sense are ignored rather than crashing", %{conn: conn} do
    {:ok, log} = Audit.log_event(:client_created, "Client", 4, label: "Beta Co")

    {:ok, view, _html} =
      live(conn, ~p"/settings/audit-logs?who=999999&category=Nope&from=yesterday&to=")

    assert has_element?(view, "#audit-row-#{log.id}")
    refute has_element?(view, "#audit-clear-filters")
  end

  test "the drawer shows what changed, with money in rupees and secrets hidden", %{conn: conn} do
    {:ok, log} =
      Audit.log_event(:invoice_updated, "Invoice", 9,
        label: "INV-0009",
        changes: %{
          "grand_total" => %{"from" => 100_000, "to" => 150_000},
          "smtp_password" => %{"redacted" => true}
        }
      )

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs")
    view |> element("#audit-row-#{log.id} button") |> render_click()

    assert has_element?(view, "#audit-log-drawer")
    assert has_element?(view, "#audit-changes #audit-change-grand_total")

    total = view |> element("#audit-change-grand_total") |> render()
    assert total =~ "1,000"
    assert total =~ "1,500"

    assert render(element(view, "#audit-change-smtp_password")) =~ "value hidden"

    view |> element("#audit-log-drawer-close") |> render_click()
    refute has_element?(view, "#audit-log-drawer")
  end

  test "the drawer formats an accepted quotation total as money", %{conn: conn} do
    {:ok, log} =
      Audit.log_event(:quotation_accepted, "Quotation", 42,
        label: "QT-0042",
        accepted_revision: 3,
        accepted_total: 118_000,
        currency: "INR"
      )

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs")
    view |> element("#audit-row-#{log.id} button") |> render_click()

    details = view |> element("#audit-log-drawer dl") |> render()
    assert details =~ "Accepted total"
    assert details =~ "1,180"
    refute details =~ "118000"
  end

  test "the drawer links to a record only while it can still be opened", %{conn: conn} do
    {:ok, gone} = Audit.log_event(:bin_invoice, "Invoice", 123_456, label: "INV-GONE")
    {:ok, settings} = Audit.log_event(:settings_updated, "Settings", "company", label: "Company")

    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs")

    view |> element("#audit-row-#{gone.id} button") |> render_click()
    refute has_element?(view, "#audit-record-link")

    view |> element("#audit-row-#{settings.id} button") |> render_click()
    assert has_element?(view, "#audit-record-link[href='/settings/company']")
  end

  test "new entries appear without a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/audit-logs")

    {:ok, log} = Audit.log_event(:client_created, "Client", 5, label: "Live Co")

    assert render(view) =~ "Live Co"
    assert has_element?(view, "#audit-row-#{log.id}")
  end

  test "staff are refused: it holds every member's actions and addresses" do
    conn = log_in_user(build_conn(), AccountsFixtures.user_fixture())

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/settings/audit-logs")
  end
end
