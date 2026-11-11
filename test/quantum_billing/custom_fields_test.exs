defmodule QuantumBilling.CustomFieldsTest do
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Businesses
  alias QuantumBilling.Clients
  alias QuantumBilling.CustomFields
  alias QuantumBilling.CustomFields.FieldDefinition
  alias QuantumBilling.Invoices

  defp scope_for(user) do
    business = Businesses.default!()
    Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))
  end

  setup do
    %{owner: scope_for(owner_fixture()), staff: scope_for(user_fixture())}
  end

  defp field!(scope, object, attrs) do
    {:ok, definition} = CustomFields.create_definition(scope, object, attrs)
    definition
  end

  defp client!(attrs \\ %{}) do
    {:ok, client} =
      Clients.create_client(
        Map.merge(
          %{
            "name" => "Acme #{System.unique_integer([:positive])}",
            "phone" => "9876543210",
            "billing_line1" => "1 Park Street",
            "billing_city" => "Mumbai",
            "billing_state" => "Maharashtra (27)",
            "billing_pin" => "400093",
            "client_type" => "Unregistered"
          },
          attrs
        )
      )

    client
  end

  defp definition(type, options \\ %{}),
    do: %FieldDefinition{type: type, options: options, label: "Field"}

  describe "FieldDefinition.cast_value/2" do
    test "text and long text trim and cap their length" do
      assert {:ok, "PO-1"} = FieldDefinition.cast_value(definition("text"), "  PO-1 ")
      assert :empty = FieldDefinition.cast_value(definition("text"), "   ")

      assert {:error, _} =
               FieldDefinition.cast_value(definition("text"), String.duplicate("a", 501))

      assert {:ok, _} =
               FieldDefinition.cast_value(definition("long_text"), String.duplicate("a", 5000))
    end

    test "numbers are stored as decimal strings without separators" do
      assert {:ok, "1250.50"} = FieldDefinition.cast_value(definition("number"), "1,250.50")
      assert {:ok, "3"} = FieldDefinition.cast_value(definition("number"), 3)
      assert {:error, _} = FieldDefinition.cast_value(definition("number"), "12abc")
    end

    test "money is typed in rupees and stored in paise" do
      assert {:ok, 125_050} = FieldDefinition.cast_value(definition("money"), "₹1,250.50")
      assert {:error, _} = FieldDefinition.cast_value(definition("money"), "lots")
    end

    test "dates, booleans, emails, phones and urls" do
      assert {:ok, "2026-11-05"} = FieldDefinition.cast_value(definition("date"), "2026-11-05")
      assert {:error, _} = FieldDefinition.cast_value(definition("date"), "05/11/2026")
      assert {:ok, true} = FieldDefinition.cast_value(definition("boolean"), "true")
      assert {:ok, false} = FieldDefinition.cast_value(definition("boolean"), "false")
      assert {:ok, "a@b.in"} = FieldDefinition.cast_value(definition("email"), "a@b.in")
      assert {:error, _} = FieldDefinition.cast_value(definition("email"), "not-an-email")
      assert {:ok, _} = FieldDefinition.cast_value(definition("phone"), "+91 98765 43210")
      assert {:error, _} = FieldDefinition.cast_value(definition("phone"), "call me")
      assert {:ok, _} = FieldDefinition.cast_value(definition("url"), "https://example.in/x")
      assert {:error, _} = FieldDefinition.cast_value(definition("url"), "javascript:alert(1)")
    end

    test "choices accept the id or the label and store the id" do
      choices = %{
        "choices" => [
          %{"id" => "north", "label" => "North", "color" => "blue"},
          %{"id" => "south", "label" => "South", "color" => "green"}
        ]
      }

      assert {:ok, "north"} = FieldDefinition.cast_value(definition("select", choices), "north")
      assert {:ok, "south"} = FieldDefinition.cast_value(definition("select", choices), "south")
      assert {:ok, "south"} = FieldDefinition.cast_value(definition("select", choices), "SOUTH")
      assert {:error, _} = FieldDefinition.cast_value(definition("select", choices), "east")

      assert {:ok, ["north", "south"]} =
               FieldDefinition.cast_value(definition("multi_select", choices), [
                 "North",
                 "south",
                 "north"
               ])

      assert :empty = FieldDefinition.cast_value(definition("multi_select", choices), [""])
    end
  end

  describe "create_definition/3" do
    test "makes a key from the label and keeps it unique", %{owner: owner} do
      first = field!(owner, "client", %{"label" => "PO Number", "type" => "text"})
      second = field!(owner, "client", %{"label" => "PO number!", "type" => "text"})
      numeric = field!(owner, "client", %{"label" => "2nd contact", "type" => "text"})

      assert first.key == "po_number"
      assert second.key == "po_number_2"
      assert numeric.key == "field_2nd_contact"
      assert [0, 1, 2] == Enum.map(CustomFields.list_definitions("client"), & &1.position)
    end

    test "is refused to staff", %{staff: staff} do
      assert {:error, :unauthorized} =
               CustomFields.create_definition(staff, "client", %{"label" => "X", "type" => "text"})
    end

    test "is audited", %{owner: owner} do
      definition = field!(owner, "invoice", %{"label" => "Project", "type" => "text"})

      assert Repo.exists?(
               from a in AuditLog,
                 where:
                   a.action == "custom_field_created" and
                     a.resource_id == ^to_string(definition.id) and
                     a.user_id == ^owner.user.id
             )
    end

    test "cleans the choices and gives each a stable id", %{owner: owner} do
      definition =
        field!(owner, "client", %{
          "label" => "Region",
          "type" => "select",
          "choices" => %{
            "0" => %{"label" => "North", "color" => "blue"},
            "1" => %{"label" => "  "},
            "2" => %{"label" => "South", "color" => "chartreuse"}
          },
          "default" => "South"
        })

      assert [
               %{"id" => "north", "label" => "North", "color" => "blue"},
               %{"id" => "south", "label" => "South", "color" => "gray"}
             ] = FieldDefinition.choices(definition)

      assert FieldDefinition.default(definition) == "south"

      # Renaming a choice keeps its id, so stored values still point at it.
      {:ok, renamed} =
        CustomFields.update_definition(owner, definition, %{
          "choices" => [
            %{"id" => "north", "label" => "Northern", "color" => "blue"},
            %{"id" => "south", "label" => "South", "color" => "gray"}
          ]
        })

      assert FieldDefinition.choice_label(renamed, "north") == "Northern"
    end

    test "refuses bad choices and a bad default", %{owner: owner} do
      assert {:error, changeset} =
               CustomFields.create_definition(owner, "client", %{
                 "label" => "R",
                 "type" => "select"
               })

      assert "add at least one choice" in errors_on(changeset).options

      assert {:error, changeset} =
               CustomFields.create_definition(owner, "client", %{
                 "label" => "R",
                 "type" => "select",
                 "choices" => [%{"label" => "A"}, %{"label" => "a"}]
               })

      assert "has the same choice twice" in errors_on(changeset).options

      assert {:error, changeset} =
               CustomFields.create_definition(owner, "client", %{
                 "label" => "Count",
                 "type" => "number",
                 "default" => "many"
               })

      assert "default must be a number" in errors_on(changeset).options
    end

    test "drops flags that mean nothing for the type or object", %{owner: owner} do
      definition =
        field!(owner, "e_way_bill", %{
          "label" => "Note",
          "type" => "text",
          "filterable" => "true",
          "show_in_list" => "true",
          "show_on_invoice" => "true"
        })

      refute definition.filterable
      refute definition.show_in_list
      refute definition.show_on_invoice

      # A choice field off the list pages can't filter; a client field never prints.
      line =
        field!(owner, "invoice_item", %{
          "label" => "Grade",
          "type" => "boolean",
          "filterable" => "true",
          "show_on_invoice" => "true"
        })

      refute line.filterable
      assert line.show_on_invoice

      client =
        field!(owner, "client", %{
          "label" => "Code",
          "type" => "text",
          "show_on_invoice" => "true"
        })

      refute client.show_on_invoice
    end

    test "stops at the limit of active fields", %{owner: owner} do
      for n <- 1..CustomFields.max_active() do
        field!(owner, "credit_note", %{"label" => "Field #{n}", "type" => "text"})
      end

      assert {:error, :limit_reached} =
               CustomFields.create_definition(owner, "credit_note", %{
                 "label" => "One more",
                 "type" => "text"
               })
    end
  end

  describe "record values" do
    setup %{owner: owner} do
      %{
        po: field!(owner, "client", %{"label" => "PO", "type" => "text"}),
        limit: field!(owner, "client", %{"label" => "Limit", "type" => "money"})
      }
    end

    test "are validated and stored by key; unknown keys are dropped" do
      client = client!(%{"custom_fields" => %{"po" => "PO-9", "limit" => "1500", "nope" => "x"}})
      assert client.custom_fields == %{"po" => "PO-9", "limit" => 150_000}
    end

    test "a bad value is an error on its key" do
      assert {:error, changeset} =
               Clients.create_client(%{
                 "name" => "Acme",
                 "phone" => "9876543210",
                 "client_type" => "Unregistered",
                 "billing_line1" => "1 Park Street",
                 "billing_city" => "Mumbai",
                 "billing_state" => "Maharashtra (27)",
                 "billing_pin" => "400093",
                 "custom_fields" => %{"limit" => "lots"}
               })

      assert CustomFields.error_for(changeset, "limit") =~ "must be an amount"
    end

    test "a blank value removes the key; attrs without custom_fields leave them alone" do
      client = client!(%{"custom_fields" => %{"po" => "PO-9", "limit" => "10"}})

      {:ok, client} = Clients.update_client(client, %{"custom_fields" => %{"po" => ""}})
      assert client.custom_fields == %{"limit" => 1000}

      {:ok, client} = Clients.update_client(client, %{"notes" => "Called"})
      assert client.custom_fields == %{"limit" => 1000}
    end

    test "archived fields keep their values", %{owner: owner, po: po} do
      client = client!(%{"custom_fields" => %{"po" => "PO-9"}})
      {:ok, _archived} = CustomFields.archive_definition(owner, po)

      {:ok, client} =
        Clients.update_client(client, %{"custom_fields" => %{"po" => "changed", "limit" => "5"}})

      assert client.custom_fields == %{"po" => "PO-9", "limit" => 500}
    end

    test "a required field must be filled", %{owner: owner} do
      field!(owner, "client", %{"label" => "Region code", "type" => "text", "required" => "true"})

      assert {:error, changeset} =
               Clients.create_client(%{
                 "name" => "Acme",
                 "phone" => "9876543210",
                 "client_type" => "Unregistered",
                 "billing_line1" => "1 Park Street",
                 "billing_city" => "Mumbai",
                 "billing_state" => "Maharashtra (27)",
                 "billing_pin" => "400093",
                 "custom_fields" => %{"region_code" => " "}
               })

      assert CustomFields.error_for(changeset, "region_code") =~ "can't be blank"
    end

    test "invoice items carry their own fields", %{owner: owner} do
      field!(owner, "invoice_item", %{"label" => "Batch", "type" => "text"})
      field!(owner, "invoice", %{"label" => "Project", "type" => "text"})
      client = client!()

      {:ok, invoice} =
        Invoices.create_invoice(%{
          "client_id" => client.id,
          "client_name" => client.name,
          "invoice_date" => "2026-03-01",
          "place_of_supply" => "Maharashtra (27)",
          "custom_fields" => %{"project" => "Apollo"},
          "items" => %{
            "0" => %{
              "description" => "Widgets",
              "quantity" => "2",
              "unit" => "Nos",
              "rate" => "100",
              "tax_rate" => "18",
              "custom_fields" => %{"batch" => "B-17"}
            }
          }
        })

      assert invoice.custom_fields == %{"project" => "Apollo"}
      assert [%{custom_fields: %{"batch" => "B-17"}}] = invoice.items
    end
  end

  describe "update_definition/3 type changes" do
    test "are free until a record holds a value", %{owner: owner} do
      definition = field!(owner, "client", %{"label" => "Score", "type" => "number"})
      {:ok, definition} = CustomFields.update_definition(owner, definition, %{"type" => "text"})
      assert definition.type == "text"

      client!(%{"custom_fields" => %{"score" => "7"}})

      assert {:error, changeset} =
               CustomFields.update_definition(owner, definition, %{"type" => "date"})

      assert errors_on(changeset).type != []

      {:ok, definition} =
        CustomFields.update_definition(owner, definition, %{"type" => "long_text"})

      assert definition.type == "long_text"
    end

    test "select to multiple choice wraps stored values in a list", %{owner: owner} do
      definition =
        field!(owner, "client", %{
          "label" => "Tier",
          "type" => "select",
          "choices" => [%{"label" => "Gold"}, %{"label" => "Silver"}]
        })

      client = client!(%{"custom_fields" => %{"tier" => "Gold"}})
      untouched = client!()

      {:ok, definition} =
        CustomFields.update_definition(owner, definition, %{"type" => "multi_select"})

      assert definition.type == "multi_select"
      assert Clients.get_client!(client.id).custom_fields == %{"tier" => ["gold"]}
      assert Clients.get_client!(untouched.id).custom_fields == %{}
    end
  end

  describe "archive, restore, delete and move" do
    test "a field is deleted only once archived and unused", %{owner: owner, staff: staff} do
      definition = field!(owner, "client", %{"label" => "Ref", "type" => "text"})
      assert {:error, :not_archived} = CustomFields.delete_definition(owner, definition)

      client = client!(%{"custom_fields" => %{"ref" => "R1"}})
      {:ok, definition} = CustomFields.archive_definition(owner, definition)
      assert CustomFields.list_definitions("client") == []
      assert {:error, :in_use} = CustomFields.delete_definition(owner, definition)
      assert {:error, :unauthorized} = CustomFields.delete_definition(staff, definition)

      {:ok, _client} = Repo.update(Ecto.Changeset.change(client, custom_fields: %{}))
      assert {:ok, _deleted} = CustomFields.delete_definition(owner, definition)
      assert CustomFields.list_definitions("client", archived: :include) == []
    end

    test "restore puts the field back at the end", %{owner: owner} do
      first = field!(owner, "client", %{"label" => "A", "type" => "text"})
      field!(owner, "client", %{"label" => "B", "type" => "text"})
      {:ok, first} = CustomFields.archive_definition(owner, first)
      {:ok, _restored} = CustomFields.restore_definition(owner, first)

      assert ["b", "a"] == Enum.map(CustomFields.list_definitions("client"), & &1.key)
    end

    test "move swaps neighbours and stops at the ends", %{owner: owner} do
      a = field!(owner, "client", %{"label" => "A", "type" => "text"})
      b = field!(owner, "client", %{"label" => "B", "type" => "text"})

      {:ok, _moved} = CustomFields.move(owner, b, :up)
      assert ["b", "a"] == Enum.map(CustomFields.list_definitions("client"), & &1.key)

      {:ok, _unmoved} = CustomFields.move(owner, Repo.reload!(b), :up)
      assert ["b", "a"] == Enum.map(CustomFields.list_definitions("client"), & &1.key)

      {:ok, _moved} = CustomFields.move(owner, Repo.reload!(a), :up)
      assert ["a", "b"] == Enum.map(CustomFields.list_definitions("client"), & &1.key)
    end
  end

  describe "filtering lists" do
    setup %{owner: owner} do
      region =
        field!(owner, "client", %{
          "label" => "Region",
          "type" => "select",
          "filterable" => "true",
          "choices" => %{"0" => %{"label" => "North"}, "1" => %{"label" => "South"}}
        })

      vip =
        field!(owner, "client", %{"label" => "VIP", "type" => "boolean", "filterable" => "true"})

      note = field!(owner, "client", %{"label" => "Note", "type" => "text"})
      [north, south] = Enum.map(FieldDefinition.choices(region), & &1["id"])

      %{region: region, vip: vip, note: note, north: north, south: south}
    end

    defp names(filters) do
      [search: "Filt", custom: filters]
      |> Clients.page()
      |> Map.fetch!(:rows)
      |> Enum.map(& &1.name)
      |> Enum.sort()
    end

    test "matches choices and booleans, and No includes unset", %{north: north, south: south} do
      client!(%{"name" => "Filt A", "custom_fields" => %{"region" => north, "vip" => "true"}})
      client!(%{"name" => "Filt B", "custom_fields" => %{"region" => south, "vip" => "false"}})
      client!(%{"name" => "Filt C"})

      assert names(%{"region" => north}) == ["Filt A"]
      assert names(%{"vip" => "true"}) == ["Filt A"]
      assert names(%{"vip" => "false"}) == ["Filt B", "Filt C"]
      assert names(%{"region" => south, "vip" => "true"}) == []
    end

    test "ignores unknown keys, non-filterable fields and bad values", %{north: north} do
      client!(%{"name" => "Filt A", "custom_fields" => %{"region" => north, "note" => "x"}})
      client!(%{"name" => "Filt B"})

      all = ["Filt A", "Filt B"]
      assert names(%{"nope" => "x"}) == all
      assert names(%{"note" => "x"}) == all
      assert names(%{"region" => "not-a-choice"}) == all
    end
  end
end
