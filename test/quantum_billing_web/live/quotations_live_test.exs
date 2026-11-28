defmodule QuantumBillingWeb.QuotationsLiveTest do
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.CustomFieldsFixtures, only: [field_fixture: 2]
  import QuantumBilling.QuotationsFixtures

  alias QuantumBilling.Quotations
  alias QuantumBilling.Repo
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

  defp expire(quotation) do
    today = Quotations.today()

    quotation
    |> Ecto.Changeset.change(
      quotation_date: Date.add(today, -40),
      valid_until: Date.add(today, -1)
    )
    |> Repo.update!()
  end

  describe "list" do
    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/quotations")
    end

    test "is in the sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/quotations")
      assert has_element?(view, "#nav-quotations")
    end

    test "lists quotations, with an empty state when there are none", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/quotations")
      refute has_element?(view, "#quotations tr")

      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations")

      assert has_element?(view, "#quotation-#{quotation.id}", quotation.number)
      assert has_element?(view, "#new-quotation")
    end

    test "search narrows the list", %{conn: conn, scope: scope} do
      bluewave = quotation_fixture(scope, %{"client_name" => "Bluewave Retail"})
      green = quotation_fixture(scope, %{"client_name" => "Green Leaf"})
      {:ok, view, _html} = live(conn, ~p"/quotations")

      view |> form("#quotation-search", %{"q" => "bluewave"}) |> render_change()

      assert has_element?(view, "#quotation-#{bluewave.id}")
      refute has_element?(view, "#quotation-#{green.id}")
    end

    test "status tabs narrow the list, Expired included", %{conn: conn, scope: scope} do
      draft = quotation_fixture(scope)
      expired = scope |> quotation_fixture() |> expire()
      accepted = accepted_quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations")

      view |> element("#quotation-status-expired") |> render_click()
      assert has_element?(view, "#quotation-#{expired.id}", "Expired")
      refute has_element?(view, "#quotation-#{draft.id}")
      refute has_element?(view, "#quotation-#{accepted.id}")

      view |> element("#quotation-status-draft") |> render_click()
      assert has_element?(view, "#quotation-#{draft.id}")
      refute has_element?(view, "#quotation-#{expired.id}")

      view |> element("#quotation-status-accepted") |> render_click()
      assert has_element?(view, "#quotation-#{accepted.id}")
      refute has_element?(view, "#quotation-#{draft.id}")
    end

    test "deletes a quotation", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations")

      view |> element("#quotation-delete-#{quotation.id}") |> render_click()

      refute has_element?(view, "#quotation-#{quotation.id}")
      assert Quotations.get_quotation(quotation.id) == nil
      assert Quotations.get_deleted_quotation(quotation.id)
    end
  end

  describe "form" do
    test "shows the number it will take and a default validity", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/quotations/new")

      assert has_element?(view, "#quotation-number", "QT-0001")

      valid_until = Date.to_iso8601(Date.add(Quotations.today(), 30))

      assert has_element?(
               view,
               ~s(#quotation-form [name="quotation[valid_until]"][value="#{valid_until}"])
             )
    end

    test "the default validity follows the business's setting", %{conn: conn} do
      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{"quotation_validity_days" => "15"},
          :invoice
        )

      {:ok, view, _html} = live(conn, ~p"/quotations/new")

      valid_until = Date.to_iso8601(Date.add(Quotations.today(), 15))

      assert has_element?(
               view,
               ~s(#quotation-form [name="quotation[valid_until]"][value="#{valid_until}"])
             )
    end

    test "saves the quotation's custom fields", %{conn: conn} do
      field_fixture("quotation", %{"label" => "Project code", "type" => "text"})

      {:ok, view, _html} = live(conn, ~p"/quotations/new")

      assert has_element?(
               view,
               ~s(#quotation-custom-fields [name="quotation[custom_fields][project_code]"])
             )

      params = quotation_params(%{"custom_fields" => %{"project_code" => "PRJ-7"}})

      assert {:error, {:live_redirect, %{to: "/quotations/" <> id}}} =
               view |> form("#quotation-form", %{"quotation" => params}) |> render_submit()

      assert Quotations.get_quotation(String.to_integer(id)).custom_fields == %{
               "project_code" => "PRJ-7"
             }
    end

    test "creates a quotation and lands on it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/quotations/new")

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> form("#quotation-form", %{"quotation" => quotation_params()})
               |> render_submit()

      assert %{rows: [quotation]} = Quotations.page()
      assert path == "/quotations/#{quotation.id}"
      assert quotation.number == "QT-0001"
      assert quotation.status == "Draft"
      assert quotation.grand_total == 5_900_000
    end

    test "shows errors for a validity date before the quotation date", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/quotations/new")
      yesterday = Date.to_iso8601(Date.add(Quotations.today(), -1))

      html =
        view
        |> form("#quotation-form", %{
          "quotation" => quotation_params(%{"valid_until" => yesterday})
        })
        |> render_submit()

      assert html =~ "cannot be before the quotation date"
      assert Quotations.page().rows == []
    end

    test "edits a draft", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}/edit")

      assert has_element?(view, "#quotation-number", quotation.number)

      assert {:error, {:live_redirect, %{to: path}}} =
               view
               |> form("#quotation-form", %{"quotation" => %{"client_name" => "Renamed Client"}})
               |> render_submit()

      assert path == "/quotations/#{quotation.id}"
      assert Quotations.get_quotation(quotation.id).client_name == "Renamed Client"
      refute has_element?(view, "#quotation-revision-warning")
    end

    test "warns when editing a sent quotation", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, sent} = Quotations.mark_sent(scope, quotation)

      {:ok, view, _html} = live(conn, ~p"/quotations/#{sent}/edit")

      assert has_element?(view, "#quotation-revision-warning")
    end

    test "won't open an accepted quotation for editing", %{conn: conn, scope: scope} do
      quotation = accepted_quotation_fixture(scope)
      path = "/quotations/#{quotation.id}"

      assert {:error, {:live_redirect, %{to: ^path}}} =
               live(conn, ~p"/quotations/#{quotation}/edit")
    end
  end
end
