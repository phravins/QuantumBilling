defmodule QuantumBilling.CustomFieldsFixtures do
  @moduledoc "Custom field definitions for tests, created as the default business's owner."

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.AccountsFixtures
  alias QuantumBilling.Businesses
  alias QuantumBilling.CustomFields

  @doc "An owner scope on the default business; makes an owner when none is given."
  def owner_scope(user \\ nil) do
    user = user || AccountsFixtures.owner_fixture()
    business = Businesses.default!()
    Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))
  end

  @doc "Creates a field on `object` with `attrs` (string keys) and returns it."
  def field_fixture(object, attrs, scope \\ nil) do
    {:ok, definition} = CustomFields.create_definition(scope || owner_scope(), object, attrs)
    definition
  end

  @doc "The id of the choice labelled `label`."
  def choice_id(definition, label) do
    definition
    |> CustomFields.FieldDefinition.choices()
    |> Enum.find_value(&(&1["label"] == label && &1["id"]))
  end
end
