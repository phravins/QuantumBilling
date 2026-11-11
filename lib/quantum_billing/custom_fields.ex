defmodule QuantumBilling.CustomFields do
  @moduledoc """
  Fields a business adds to its records, such as "PO number" on invoices.

  Definitions live in `field_definitions`; values live in each record's
  `custom_fields` JSONB column, keyed by the definition's `key`. Only owners
  change definitions, and every change is audited. Records are written through
  `cast/4`, which validates values against the active definitions.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [add_error: 4, get_field: 2, put_change: 3]

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit
  alias QuantumBilling.CustomFields.FieldDefinition
  alias QuantumBilling.Repo

  @max_active 50

  @objects [
    {"client", "Clients", "clients"},
    {"invoice", "Invoices", "invoices"},
    {"invoice_item", "Invoice items", "invoice_items"},
    {"credit_note", "Credit notes", "credit_notes"},
    {"e_way_bill", "E-way bills", "e_way_bills"},
    {"recurring_profile", "Recurring profiles", "recurring_profiles"}
  ]

  # Changes that keep every stored value readable.
  @safe_type_changes [{"text", "long_text"}, {"long_text", "text"}, {"select", "multi_select"}]

  @doc "The objects that take custom fields, as `{object, label}`."
  def objects, do: Enum.map(@objects, fn {object, label, _table} -> {object, label} end)

  def max_active, do: @max_active

  @doc """
  The object's fields in position order.

  `archived:` is `:exclude` (the default), `:only` or `:include`.
  """
  def list_definitions(object, opts \\ []) do
    query =
      from d in FieldDefinition,
        where: d.object == ^object,
        order_by: [asc: d.position, asc: d.id]

    query =
      case Keyword.get(opts, :archived, :exclude) do
        :exclude -> where(query, [d], is_nil(d.archived_at))
        :only -> where(query, [d], not is_nil(d.archived_at))
        :include -> query
      end

    Repo.all(query)
  end

  @doc "How many active fields each object has, as `%{object => count}`."
  def active_counts do
    from(d in FieldDefinition,
      where: is_nil(d.archived_at),
      group_by: d.object,
      select: {d.object, count(d.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The fields records of `object` are filled in with."
  def active_definitions(object), do: list_definitions(object)

  @doc "Active fields marked \"Include in API\", for the API and webhooks."
  def api_definitions(object),
    do: object |> active_definitions() |> Enum.filter(& &1.include_in_api)

  @doc "The stored values of `definitions` only, keyed by field key."
  def visible_values(values, definitions) do
    values = values || %{}
    for d <- definitions, Map.has_key?(values, d.key), into: %{}, do: {d.key, values[d.key]}
  end

  def get_definition!(id), do: Repo.get!(FieldDefinition, id)

  @doc "The definition with `id`, or nil. Ids from the browser may be stale."
  def get_definition(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get(FieldDefinition, id)
      _other -> nil
    end
  end

  @doc "A changeset for the add/edit form."
  def change_definition(%FieldDefinition{} = definition, attrs \\ %{}) do
    if definition.id,
      do: FieldDefinition.update_changeset(definition, attrs),
      else: FieldDefinition.create_changeset(definition, attrs, taken_keys(definition.object))
  end

  ## Managing definitions (owners only)

  @doc "Adds a field to `object`. It goes last."
  def create_definition(%Scope{} = scope, object, attrs) do
    with :ok <- authorize(scope),
         :ok <- check_room(object) do
      %FieldDefinition{object: object, position: next_position(object)}
      |> FieldDefinition.create_changeset(attrs, taken_keys(object))
      |> Repo.insert()
      |> audited(scope, :custom_field_created)
    end
  end

  @doc """
  Edits a field. The type can change freely while no record holds a value;
  after that only `text`/`long_text` and `select` → `multi_select` are allowed.
  """
  def update_definition(%Scope{} = scope, %FieldDefinition{} = definition, attrs) do
    with :ok <- authorize(scope) do
      changeset = FieldDefinition.update_changeset(definition, attrs)
      new_type = get_field(changeset, :type)

      cond do
        new_type == definition.type ->
          changeset |> Repo.update() |> audited(scope, :custom_field_updated)

        {definition.type, new_type} in @safe_type_changes ->
          change_type(changeset, definition, new_type) |> audited(scope, :custom_field_updated)

        in_use?(definition) ->
          {:error,
           add_error(changeset, :type, "can't change once records have a value for this field",
             validation: :in_use
           )}

        true ->
          changeset |> Repo.update() |> audited(scope, :custom_field_updated)
      end
    end
  end

  # select → multi_select wraps every stored id in a list, in the same transaction.
  defp change_type(changeset, %{type: "select"} = definition, "multi_select") do
    Repo.transaction(fn ->
      table = table!(definition.object)
      key = definition.key

      from(r in table,
        where: fragment("jsonb_exists(?, ?)", r.custom_fields, ^key),
        update: [
          set: [
            custom_fields:
              fragment(
                "jsonb_set(?, ARRAY[?]::text[], jsonb_build_array(? -> ?))",
                r.custom_fields,
                ^key,
                r.custom_fields,
                ^key
              )
          ]
        ]
      )
      |> Repo.update_all([])

      case Repo.update(changeset) do
        {:ok, definition} -> definition
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp change_type(changeset, _definition, _type), do: Repo.update(changeset)

  @doc "Hides a field from forms and lists. Its values are kept."
  def archive_definition(%Scope{} = scope, %FieldDefinition{} = definition) do
    with :ok <- authorize(scope) do
      definition
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
      |> Repo.update()
      |> audited(scope, :custom_field_archived)
    end
  end

  @doc "Brings an archived field back, at the end of the list."
  def restore_definition(%Scope{} = scope, %FieldDefinition{} = definition) do
    with :ok <- authorize(scope),
         :ok <- check_room(definition.object) do
      definition
      |> Ecto.Changeset.change(archived_at: nil, position: next_position(definition.object))
      |> Repo.update()
      |> audited(scope, :custom_field_restored)
    end
  end

  @doc "Removes an archived field for good. Refused while any record holds a value."
  def delete_definition(%Scope{} = scope, %FieldDefinition{} = definition) do
    with :ok <- authorize(scope) do
      cond do
        is_nil(definition.archived_at) -> {:error, :not_archived}
        in_use?(definition) -> {:error, :in_use}
        true -> definition |> Repo.delete() |> audited(scope, :custom_field_deleted)
      end
    end
  end

  @doc "Swaps a field with its neighbour above or below."
  def move(%Scope{} = scope, %FieldDefinition{} = definition, direction)
      when direction in [:up, :down] do
    with :ok <- authorize(scope) do
      fields = list_definitions(definition.object)
      index = Enum.find_index(fields, &(&1.id == definition.id))
      neighbour_index = if direction == :up, do: index && index - 1, else: index && index + 1

      if is_nil(index) or neighbour_index < 0 or neighbour_index >= length(fields) do
        {:ok, definition}
      else
        # Renumber the whole list, so equal positions can't make the swap a no-op.
        ordered =
          fields
          |> List.replace_at(index, Enum.at(fields, neighbour_index))
          |> List.replace_at(neighbour_index, Enum.at(fields, index))

        Repo.transaction(fn ->
          ordered
          |> Enum.with_index()
          |> Enum.each(fn {field, position} ->
            if field.position != position do
              Repo.update_all(from(d in FieldDefinition, where: d.id == ^field.id),
                set: [position: position]
              )
            end
          end)

          Repo.get!(FieldDefinition, definition.id)
        end)
      end
    end
  end

  @doc "Whether any record of the field's object holds a value for it, Bin included."
  def in_use?(%FieldDefinition{object: object, key: key}) do
    table = table!(object)

    Repo.exists?(from r in table, where: fragment("jsonb_exists(?, ?)", r.custom_fields, ^key))
  end

  defp authorize(scope) do
    if Scope.owner?(scope), do: :ok, else: {:error, :unauthorized}
  end

  defp check_room(object) do
    count =
      Repo.aggregate(
        from(d in FieldDefinition, where: d.object == ^object and is_nil(d.archived_at)),
        :count
      )

    if count < @max_active, do: :ok, else: {:error, :limit_reached}
  end

  defp next_position(object) do
    max =
      Repo.one(from d in FieldDefinition, where: d.object == ^object, select: max(d.position))

    (max || -1) + 1
  end

  defp taken_keys(nil), do: []

  defp taken_keys(object),
    do: Repo.all(from d in FieldDefinition, where: d.object == ^object, select: d.key)

  defp table!(object) do
    Enum.find_value(@objects, fn {key, _label, table} -> if key == object, do: table end) ||
      raise ArgumentError, "unknown custom-field object #{inspect(object)}"
  end

  defp audited({:ok, definition} = result, scope, action) do
    Audit.log_event(action, "FieldDefinition", definition.id,
      user_id: scope.user.id,
      details: %{
        "object" => definition.object,
        "key" => definition.key,
        "label" => definition.label,
        "type" => definition.type
      }
    )

    result
  end

  defp audited(error, _scope, _action), do: error

  ## Record values

  @doc """
  Validates `attrs["custom_fields"]` onto a record changeset of `object`.

  Does nothing unless the attrs carry `custom_fields`. Only active fields are
  touched: unknown keys are dropped and archived fields keep their values. A
  blank value removes the key. Errors go on `:custom_fields` with the field's
  key, so a form can show each one under its input.

  `definitions` saves a query when the caller already has them.

  Records the app writes itself (recurring invoices) set the atom key
  `custom_fields_system: true`, which skips `required`: a field added later
  must not stop the job. Browser and API params have string keys, so they
  can't set it.
  """
  def cast(%Ecto.Changeset{} = changeset, object, attrs, definitions \\ nil) do
    case fetch_values(attrs) do
      {:ok, submitted} when is_map(submitted) ->
        definitions = definitions || active_definitions(object)
        current = get_field(changeset, :custom_fields) || %{}
        submitted = Map.new(submitted, fn {key, value} -> {to_string(key), value} end)
        system? = Map.get(attrs, :custom_fields_system) == true

        {values, changeset} =
          Enum.reduce(definitions, {current, changeset}, fn definition, {values, changeset} ->
            definition = if system?, do: %{definition | required: false}, else: definition
            cast_one(definition, submitted, values, changeset)
          end)

        if values == current, do: changeset, else: put_change(changeset, :custom_fields, values)

      {:ok, _not_a_map} ->
        add_error(changeset, :custom_fields, "is invalid", [])

      :error ->
        changeset
    end
  end

  defp cast_one(definition, submitted, values, changeset) do
    key = definition.key

    case Map.fetch(submitted, key) do
      :error ->
        # Not on this form: keep the stored value, but a new record still needs it.
        if definition.required and definition.type != "boolean" and
             not Map.has_key?(values, key) and is_nil(Map.get(changeset.data, :id)) do
          {values,
           add_error(changeset, :custom_fields, "#{definition.label} can't be blank", key: key)}
        else
          {values, changeset}
        end

      {:ok, raw} ->
        case FieldDefinition.cast_value(definition, raw) do
          {:ok, value} ->
            {Map.put(values, key, value), changeset}

          :empty ->
            changeset =
              if definition.required and definition.type != "boolean",
                do:
                  add_error(changeset, :custom_fields, "#{definition.label} can't be blank",
                    key: key
                  ),
                else: changeset

            {Map.delete(values, key), changeset}

          {:error, message} ->
            {values,
             add_error(changeset, :custom_fields, "#{definition.label} #{message}", key: key)}
        end
    end
  end

  defp fetch_values(attrs) when is_map(attrs) do
    case Map.fetch(attrs, "custom_fields") do
      {:ok, values} -> {:ok, values}
      :error -> Map.fetch(attrs, :custom_fields)
    end
  end

  defp fetch_values(_attrs), do: :error

  @doc """
  `values` of `from` fields, re-keyed for the `to` fields that share a key and
  type, in the input form `cast/4` takes. Choices are matched by label, and
  values with no match are left out.
  """
  def carry_over(values, from_definitions, to_definitions) when is_map(values) do
    to_by_key = Map.new(to_definitions, &{&1.key, &1})

    for from <- from_definitions,
        Map.has_key?(values, from.key),
        %FieldDefinition{type: type} = to <- [Map.get(to_by_key, from.key)],
        type == from.type,
        value = carry_value(from, to, Map.fetch!(values, from.key)),
        value not in [nil, []],
        into: %{},
        do: {to.key, value}
  end

  def carry_over(_values, _from, _to), do: %{}

  defp carry_value(%{type: "money"}, _to, paise) when is_integer(paise),
    do: QuantumBilling.Money.to_input(paise)

  defp carry_value(%{type: "select"} = from, to, id), do: same_choice(from, to, id)

  defp carry_value(%{type: "multi_select"} = from, to, ids) when is_list(ids),
    do: ids |> Enum.map(&same_choice(from, to, &1)) |> Enum.reject(&is_nil/1)

  defp carry_value(_from, _to, value), do: value

  defp same_choice(from, to, id) do
    with %{"label" => label} <- FieldDefinition.choice(from, id),
         %{"id" => to_id} <-
           Enum.find(
             FieldDefinition.choices(to),
             &(String.downcase(&1["label"]) == String.downcase(label))
           ) do
      to_id
    else
      _no_match -> nil
    end
  end

  ## Filtering lists

  @doc "The fields a list of `object` can be filtered by."
  def filter_definitions(definitions) do
    Enum.filter(definitions, &(&1.filterable and FieldDefinition.filterable_type?(&1.type)))
  end

  @doc """
  Narrows `query` to records whose custom fields match `filters`, a map of
  `key => value` from the browser or API. Keys that aren't filterable fields
  of `definitions`, and values that don't cast, are ignored.

  Matches use JSONB containment, so the GIN index on `custom_fields` applies.
  A boolean "No" also matches records that never had the field set.
  """
  def filter_where(query, _definitions, filters) when filters in [nil, %{}], do: query

  def filter_where(query, definitions, filters) when is_map(filters) do
    by_key = Map.new(filter_definitions(definitions), &{&1.key, &1})

    Enum.reduce(filters, query, fn {key, raw}, query ->
      with %FieldDefinition{} = definition <- Map.get(by_key, to_string(key)),
           {:ok, value} <- FieldDefinition.cast_value(definition, raw) do
        contains(query, definition, value)
      else
        _ignored -> query
      end
    end)
  end

  def filter_where(query, _definitions, _filters), do: query

  defp contains(query, %{type: "boolean", key: key}, false) do
    where(query, [r], not fragment("? @> ?", r.custom_fields, type(^%{key => true}, :map)))
  end

  defp contains(query, %{key: key}, value) do
    where(query, [r], fragment("? @> ?", r.custom_fields, type(^%{key => value}, :map)))
  end
end
