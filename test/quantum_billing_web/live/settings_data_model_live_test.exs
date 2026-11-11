defmodule QuantumBillingWeb.SettingsLive.DataModelTest do
  @moduledoc "The owner-only Data model page."
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Businesses
  alias QuantumBilling.CustomFields

  defp owner_scope(user) do
    Scope.put_membership(
      Scope.for_user(user),
      Businesses.get_membership(user, Businesses.default!().id)
    )
  end

  defp keys(object), do: Enum.map(CustomFields.list_definitions(object), & &1.key)

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "adds a text field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/data-model")
      assert has_element?(view, "#fields-empty")

      view |> element("#new-field") |> render_click()
      assert has_element?(view, "#field-dialog")

      view
      |> form("#field-form", %{"field" => %{"label" => "PO number", "type" => "text"}})
      |> render_submit()

      refute has_element?(view, "#field-dialog")
      assert [%{key: "po_number", id: id}] = CustomFields.list_definitions("client")
      assert has_element?(view, "#field-#{id}")
    end

    test "adds a single-choice field with choices", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/data-model?object=invoice")
      view |> element("#new-field") |> render_click()

      view
      |> form("#field-form", %{"field" => %{"label" => "Region", "type" => "select"}})
      |> render_change()

      assert has_element?(view, "#field-choices")
      view |> element("#add-choice") |> render_click()
      view |> element("#add-choice") |> render_click()
      assert has_element?(view, "#choice-row-1")

      view
      |> form("#field-form", %{
        "field" => %{
          "label" => "Region",
          "type" => "select",
          "choices" => %{
            "0" => %{"id" => "", "label" => "North", "color" => "blue"},
            "1" => %{"id" => "", "label" => "South", "color" => "green"}
          }
        }
      })
      |> render_submit()

      assert [definition] = CustomFields.list_definitions("invoice")
      assert Enum.map(definition.options["choices"], & &1["label"]) == ["North", "South"]
    end

    test "shows errors and keeps the dialog open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/data-model")
      view |> element("#new-field") |> render_click()

      view
      |> form("#field-form", %{"field" => %{"label" => "", "type" => "select"}})
      |> render_submit()

      assert has_element?(view, "#field-dialog")
      assert CustomFields.list_definitions("client") == []
    end

    test "edits, reorders, archives and restores", %{conn: conn, user: user} do
      scope = owner_scope(user)

      {:ok, a} =
        CustomFields.create_definition(scope, "client", %{"label" => "A", "type" => "text"})

      {:ok, b} =
        CustomFields.create_definition(scope, "client", %{"label" => "B", "type" => "text"})

      {:ok, view, _html} = live(conn, ~p"/settings/data-model")

      view |> element("#edit-field-#{a.id}") |> render_click()

      view
      |> form("#field-form", %{"field" => %{"label" => "Alpha", "type" => "text"}})
      |> render_submit()

      assert CustomFields.get_definition!(a.id).label == "Alpha"
      # The key never changes, so stored values keep pointing at it.
      assert CustomFields.get_definition!(a.id).key == "a"

      view |> element("#move-down-#{a.id}") |> render_click()
      assert keys("client") == ["b", "a"]

      view |> element("#archive-field-#{b.id}") |> render_click()
      assert keys("client") == ["a"]
      assert has_element?(view, "#archived-field-#{b.id}")

      view |> element("#restore-field-#{b.id}") |> render_click()
      assert keys("client") == ["a", "b"]
    end

    test "deletes an archived, unused field", %{conn: conn, user: user} do
      scope = owner_scope(user)

      {:ok, field} =
        CustomFields.create_definition(scope, "client", %{"label" => "Old", "type" => "text"})

      {:ok, _archived} = CustomFields.archive_definition(scope, field)

      {:ok, view, _html} = live(conn, ~p"/settings/data-model")
      view |> element("#delete-field-#{field.id}") |> render_click()

      assert CustomFields.get_definition(field.id) == nil
      refute has_element?(view, "#archived-field-#{field.id}")
    end

    test "switches tabs by record type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/data-model")
      view |> element("#object-tab-e_way_bill") |> render_click()
      assert_patch(view, ~p"/settings/data-model?object=e_way_bill")
    end
  end

  describe "as staff" do
    setup :register_and_log_in_user

    test "is refused", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/settings/data-model")
    end
  end
end
