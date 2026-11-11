defmodule QuantumBilling.CustomFields.FieldDefinition do
  @moduledoc """
  One custom field on one kind of record, such as "PO number" on invoices.

  `key` is made from the label when the field is created and never changes, so
  renaming a field keeps its values. Select choices keep a stable `id` for the
  same reason; records store the id, not the label.

  `options` holds `"choices"` (select types) and `"default"` (prefilled in forms).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias QuantumBilling.Money

  @objects ~w(client invoice invoice_item credit_note e_way_bill recurring_profile)
  @types ~w(text long_text number money date boolean select multi_select email phone url)
  @choice_types ~w(select multi_select)
  @filterable_types ~w(select multi_select boolean)
  # An invoice prints its own and its lines' fields; the client's live ones never.
  @printable_objects ~w(invoice invoice_item)
  # Only these objects have a list page with columns and filters.
  @listed_objects ~w(client invoice)
  @colors ~w(gray blue green amber red violet)
  @max_choices 100

  schema "field_definitions" do
    field :object, :string
    field :key, :string
    field :label, :string
    field :type, :string, default: "text"
    field :options, :map, default: %{}
    field :required, :boolean, default: false
    field :help_text, :string
    field :position, :integer, default: 0
    field :show_in_list, :boolean, default: false
    field :filterable, :boolean, default: false
    field :show_on_invoice, :boolean, default: false
    field :include_in_api, :boolean, default: true
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def objects, do: @objects
  def types, do: @types
  def colors, do: @colors
  def choice_type?(type), do: type in @choice_types
  def filterable_type?(type), do: type in @filterable_types
  def printable_object?(object), do: object in @printable_objects
  def listed_object?(object), do: object in @listed_objects

  @castable ~w(label required help_text show_in_list filterable show_on_invoice include_in_api)a

  @doc "A new field. `taken_keys` are the object's existing keys, archived ones included."
  def create_changeset(%__MODULE__{} = definition, attrs, taken_keys) do
    definition
    |> cast(attrs, [:type | @castable])
    |> validate_inclusion(:object, @objects)
    |> validate_required([:object])
    |> common(attrs)
    |> put_key(taken_keys)
  end

  @doc "Editing a field. The type can change; whether it may is the context's call."
  def update_changeset(%__MODULE__{} = definition, attrs) do
    definition
    |> cast(attrs, [:type | @castable])
    |> common(attrs)
  end

  defp common(changeset, attrs) do
    changeset
    |> update_change(:label, &String.trim/1)
    |> update_change(:help_text, &String.trim/1)
    |> validate_required([:label, :type])
    |> validate_length(:label, max: 60)
    |> validate_length(:help_text, max: 200)
    |> validate_inclusion(:type, @types)
    |> put_options(attrs)
    |> drop_meaningless_flags()
  end

  # Choices come from the form as an index-keyed map, from the API as a list.
  defp put_options(changeset, attrs) do
    type = get_field(changeset, :type)
    current = get_field(changeset, :options) || %{}

    choices =
      if choice_type?(type) do
        case fetch(attrs, "choices") do
          {:ok, raw} -> normalize_choices(raw, Map.get(current, "choices", []))
          :error -> {:ok, Map.get(current, "choices", [])}
        end
      else
        {:ok, []}
      end

    case choices do
      {:ok, choices} ->
        options =
          if choices == [], do: Map.delete(current, "choices"), else: %{"choices" => choices}

        options = Map.merge(Map.drop(current, ["choices", "default"]), options)
        changeset = put_change(changeset, :options, options)

        changeset
        |> validate_choices_present(type, choices)
        |> put_default(fetch(attrs, "default"))

      {:error, message} ->
        add_error(changeset, :options, message)
    end
  end

  defp validate_choices_present(changeset, type, []) do
    if choice_type?(type),
      do: add_error(changeset, :options, "add at least one choice"),
      else: changeset
  end

  defp validate_choices_present(changeset, _type, _choices), do: changeset

  defp put_default(changeset, :error) do
    # Not sent: keep the stored default only while it still fits the field.
    definition = apply_changes(changeset)

    with {:ok, value} <- Map.fetch(definition.options, "default"),
         {:ok, value} <- cast_value(definition, value) do
      put_change(changeset, :options, Map.put(definition.options, "default", value))
    else
      _gone -> put_change(changeset, :options, Map.delete(definition.options, "default"))
    end
  end

  defp put_default(changeset, {:ok, raw}) do
    definition = apply_changes(changeset)

    case cast_value(definition, raw) do
      :empty ->
        put_change(changeset, :options, Map.delete(definition.options, "default"))

      {:ok, value} ->
        put_change(changeset, :options, Map.put(definition.options, "default", value))

      {:error, message} ->
        add_error(changeset, :options, "default #{message}")
    end
  end

  defp normalize_choices(raw, existing) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {index, _choice} -> index_order(index) end)
    |> Enum.map(fn {_index, choice} -> choice end)
    |> normalize_choices(existing)
  end

  defp normalize_choices(raw, existing) when is_list(raw) do
    rows =
      raw
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row ->
        %{
          "id" => row |> fetch_string("id") |> String.trim(),
          "label" => row |> fetch_string("label") |> String.trim(),
          "color" => row |> fetch_string("color") |> String.trim()
        }
      end)
      |> Enum.reject(&(&1["label"] == ""))

    labels = Enum.map(rows, &String.downcase(&1["label"]))
    known_ids = MapSet.new(existing, & &1["id"])

    cond do
      length(rows) > @max_choices ->
        {:error, "can have at most #{@max_choices} choices"}

      length(Enum.uniq(labels)) != length(labels) ->
        {:error, "has the same choice twice"}

      Enum.any?(rows, &(String.length(&1["label"]) > 60)) ->
        {:error, "has a choice longer than 60 characters"}

      true ->
        {choices, _taken} =
          Enum.map_reduce(rows, MapSet.new(), fn row, taken ->
            # An id is kept only if it was ours; anything else gets a fresh one.
            id =
              if row["id"] in known_ids and row["id"] not in taken,
                do: row["id"],
                else: unique_slug(row["label"], MapSet.union(taken, known_ids), "choice")

            color = if row["color"] in @colors, do: row["color"], else: "gray"
            {%{"id" => id, "label" => row["label"], "color" => color}, MapSet.put(taken, id)}
          end)

        {:ok, choices}
    end
  end

  defp normalize_choices(_raw, _existing), do: {:error, "are invalid"}

  defp index_order(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} -> number
      _other -> 0
    end
  end

  # Filtering only makes sense on fixed values; columns and filters only where a
  # list shows them; printing only where a document shows them.
  defp drop_meaningless_flags(changeset) do
    type = get_field(changeset, :type)
    object = get_field(changeset, :object)
    listed? = listed_object?(object)

    changeset
    |> then(&if(listed?, do: &1, else: put_change(&1, :show_in_list, false)))
    |> then(
      &if(listed? and filterable_type?(type), do: &1, else: put_change(&1, :filterable, false))
    )
    |> then(&if(printable_object?(object), do: &1, else: put_change(&1, :show_on_invoice, false)))
    |> then(&if(type == "boolean", do: put_change(&1, :required, false), else: &1))
  end

  defp put_key(changeset, taken_keys) do
    if changeset.valid? do
      label = get_field(changeset, :label)
      put_change(changeset, :key, unique_slug(label, MapSet.new(taken_keys), "field"))
    else
      changeset
    end
  end

  @doc false
  def unique_slug(label, taken, fallback) do
    base =
      label
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 40)

    base =
      cond do
        base == "" -> fallback
        String.match?(base, ~r/^[0-9]/) -> fallback <> "_" <> base
        true -> base
      end

    if base in taken do
      Enum.find_value(2..10_000, fn n ->
        candidate = "#{base}_#{n}"
        if candidate not in taken, do: candidate
      end)
    else
      base
    end
  end

  @doc "The select choices, in order. Empty for other types."
  def choices(%__MODULE__{options: options}), do: Map.get(options || %{}, "choices", [])

  @doc "The value a new record's form starts with, or nil."
  def default(%__MODULE__{options: options}), do: Map.get(options || %{}, "default")

  @doc "The choice with a stored id, or nil when it has gone."
  def choice(%__MODULE__{} = definition, id),
    do: Enum.find(choices(definition), &(&1["id"] == id))

  @doc "The label of a stored choice id, or nil when the choice has gone."
  def choice_label(%__MODULE__{} = definition, id) do
    case choice(definition, id) do
      %{"label" => label} -> label
      nil -> nil
    end
  end

  @doc """
  Checks one submitted value against the field's type.

  Returns `{:ok, stored}`, `:empty` when nothing was given, or `{:error, message}`.
  Money is given in rupees and stored in paise. Choices accept the id or the label.
  """
  def cast_value(definition, raw)

  def cast_value(_definition, nil), do: :empty
  def cast_value(_definition, []), do: :empty

  def cast_value(%__MODULE__{type: "multi_select"} = definition, raw) do
    values =
      raw
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    ids = Enum.map(values, &choice_id(definition, &1))

    cond do
      values == [] -> :empty
      Enum.any?(ids, &is_nil/1) -> {:error, "has a choice that isn't on the list"}
      true -> {:ok, Enum.uniq(ids)}
    end
  end

  def cast_value(%__MODULE__{type: "boolean"}, raw) do
    case raw do
      value when value in [true, "true", "on", "1", 1] -> {:ok, true}
      value when value in [false, "false", "off", "0", 0] -> {:ok, false}
      "" -> :empty
      _other -> {:error, "must be yes or no"}
    end
  end

  def cast_value(%__MODULE__{type: "money"}, raw) when is_binary(raw) or is_number(raw) do
    if blank?(raw) do
      :empty
    else
      case Money.parse(raw) do
        {:ok, paise} when abs(paise) < 100_000_000_000_000 -> {:ok, paise}
        _error -> {:error, "must be an amount, like 1250.50"}
      end
    end
  end

  def cast_value(%__MODULE__{type: "number"}, raw) when is_number(raw),
    do: cast_value(%__MODULE__{type: "number"}, to_string(raw))

  def cast_value(%__MODULE__{} = definition, raw) when is_binary(raw) do
    value = String.trim(raw)
    if value == "", do: :empty, else: cast_string(definition, value)
  end

  def cast_value(_definition, _raw), do: {:error, "is invalid"}

  defp cast_string(%{type: "text"}, value), do: max_length(value, 500)
  defp cast_string(%{type: "long_text"}, value), do: max_length(value, 5000)

  defp cast_string(%{type: "number"}, value) do
    case Decimal.parse(String.replace(value, ",", "")) do
      {decimal, ""} when byte_size(value) <= 30 -> {:ok, Decimal.to_string(decimal, :normal)}
      _error -> {:error, "must be a number"}
    end
  end

  defp cast_string(%{type: "date"}, value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      {:error, _reason} -> {:error, "must be a date"}
    end
  end

  defp cast_string(%{type: "select"} = definition, value) do
    case choice_id(definition, value) do
      nil -> {:error, "isn't one of the choices"}
      id -> {:ok, id}
    end
  end

  defp cast_string(%{type: "email"}, value) do
    if String.length(value) <= 160 and Regex.match?(~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/, value),
      do: {:ok, value},
      else: {:error, "must be an email address"}
  end

  defp cast_string(%{type: "phone"}, value) do
    if Regex.match?(~r/^\+?[0-9][0-9 ()\-]{5,19}$/, value),
      do: {:ok, value},
      else: {:error, "must be a phone number"}
  end

  defp cast_string(%{type: "url"}, value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             byte_size(value) <= 500 ->
        {:ok, value}

      _other ->
        {:error, "must be a web address starting with http:// or https://"}
    end
  end

  defp cast_string(_definition, _value), do: {:error, "is invalid"}

  defp max_length(value, max) do
    if String.length(value) <= max,
      do: {:ok, value},
      else: {:error, "should be at most #{max} characters"}
  end

  defp choice_id(definition, value) do
    choices = choices(definition)
    downcased = String.downcase(value)

    Enum.find_value(choices, fn choice -> if choice["id"] == value, do: choice["id"] end) ||
      Enum.find_value(choices, fn choice ->
        if String.downcase(choice["label"]) == downcased, do: choice["id"]
      end)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  @atom_keys %{
    "choices" => :choices,
    "default" => :default,
    "id" => :id,
    "label" => :label,
    "color" => :color
  }

  defp fetch(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Map.fetch!(@atom_keys, key))
    end
  end

  defp fetch_string(row, key) do
    case fetch(row, key) do
      {:ok, value} when is_binary(value) -> value
      _other -> ""
    end
  end
end
