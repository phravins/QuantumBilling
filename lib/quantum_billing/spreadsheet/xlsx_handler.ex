defmodule QuantumBilling.Spreadsheet.XlsxHandler do
  @moduledoc """
  Saxy handler for the parts of an .xlsx file `QuantumBilling.Spreadsheet`
  reads: the workbook (first sheet's relationship id), its relationships
  (id => part path), the shared strings, and a worksheet (rows of
  column index => text).

  Element names are compared without their namespace prefix, since some
  exporters write `x:row` where Excel writes `row`.
  """
  @behaviour Saxy.Handler

  @doc "The starting state for parsing a part of `kind`."
  def initial(:workbook, _extra), do: %{kind: :workbook, sheet_rel: nil}
  def initial(:rels, _extra), do: %{kind: :rels, rels: %{}}

  def initial(:shared_strings, _extra),
    do: %{kind: :shared_strings, strings: [], current: [], in_t: false, phonetic: 0}

  def initial(:sheet, extra) do
    %{
      kind: :sheet,
      shared: Map.get(extra, :shared, {}),
      max_rows: Map.get(extra, :max_rows, :infinity),
      rows: [],
      count: 0,
      too_many?: false,
      row: nil,
      col: nil,
      next_col: 0,
      type: nil,
      text: [],
      capture: false
    }
  end

  @impl true
  def handle_event(:start_element, {name, attributes}, state),
    do: {:ok, start_element(state.kind, local(name), attributes, state)}

  def handle_event(:end_element, name, state), do: end_element(state.kind, local(name), state)

  def handle_event(event, chars, state) when event in [:characters, :cdata],
    do: {:ok, characters(chars, state)}

  def handle_event(_event, _data, state), do: {:ok, state}

  defp local(name) do
    case String.split(name, ":") do
      [_prefix, local] -> local
      _no_prefix -> name
    end
  end

  # ── Workbook and relationships ─────────────────────────────────────────────

  defp start_element(:workbook, "sheet", attributes, %{sheet_rel: nil} = state) do
    rel = Enum.find_value(attributes, fn {key, value} -> if local(key) == "id", do: value end)
    %{state | sheet_rel: rel}
  end

  defp start_element(:rels, "Relationship", attributes, state) do
    attrs = Map.new(attributes)

    case attrs do
      %{"Id" => id, "Target" => target} -> %{state | rels: Map.put(state.rels, id, target)}
      _other -> state
    end
  end

  # ── Shared strings ─────────────────────────────────────────────────────────
  # Rich text splits a string into runs (<r><t>…</t></r>); phonetic hints
  # (<rPh>) are not part of the text.

  defp start_element(:shared_strings, "si", _attributes, state), do: %{state | current: []}

  defp start_element(:shared_strings, "rPh", _attributes, state),
    do: %{state | phonetic: state.phonetic + 1}

  defp start_element(:shared_strings, "t", _attributes, %{phonetic: 0} = state),
    do: %{state | in_t: true}

  # ── Worksheet ──────────────────────────────────────────────────────────────

  defp start_element(:sheet, "row", _attributes, state), do: %{state | row: %{}, next_col: 0}

  defp start_element(:sheet, "c", attributes, state) do
    attrs = Map.new(attributes)
    col = column_index(Map.get(attrs, "r")) || state.next_col
    %{state | col: col, type: Map.get(attrs, "t", "n"), text: []}
  end

  defp start_element(:sheet, tag, _attributes, %{col: col} = state)
       when tag in ["v", "t"] and is_integer(col),
       do: %{state | capture: true}

  defp start_element(_kind, _name, _attributes, state), do: state

  defp end_element(:shared_strings, "t", state), do: {:ok, %{state | in_t: false}}

  defp end_element(:shared_strings, "rPh", state),
    do: {:ok, %{state | phonetic: state.phonetic - 1}}

  defp end_element(:shared_strings, "si", state) do
    text = state.current |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, %{state | strings: [text | state.strings], current: []}}
  end

  defp end_element(:sheet, tag, state) when tag in ["v", "t"],
    do: {:ok, %{state | capture: false}}

  defp end_element(:sheet, "c", %{row: row, col: col} = state) when is_map(row) do
    value = state.text |> Enum.reverse() |> IO.iodata_to_binary() |> cell_value(state)
    row = if value == "", do: row, else: Map.put(row, col, value)
    {:ok, %{state | row: row, col: nil, next_col: col + 1, text: [], capture: false}}
  end

  defp end_element(:sheet, "row", %{row: row} = state) when is_map(row) do
    state = %{state | rows: [row | state.rows], count: state.count + 1, row: nil}

    if state.max_rows != :infinity and state.count > state.max_rows,
      do: {:stop, %{state | too_many?: true}},
      else: {:ok, state}
  end

  defp end_element(_kind, _name, state), do: {:ok, state}

  defp characters(chars, %{kind: :shared_strings, in_t: true} = state),
    do: %{state | current: [chars | state.current]}

  defp characters(chars, %{kind: :sheet, capture: true} = state),
    do: %{state | text: [chars | state.text]}

  defp characters(_chars, state), do: state

  # ── Cells ──────────────────────────────────────────────────────────────────

  defp cell_value(text, %{type: "s", shared: shared}) do
    case Integer.parse(text) do
      {index, ""} when index >= 0 and index < tuple_size(shared) -> elem(shared, index)
      _bad_index -> ""
    end
  end

  defp cell_value("1", %{type: "b"}), do: "TRUE"
  defp cell_value("0", %{type: "b"}), do: "FALSE"
  defp cell_value(_text, %{type: "e"}), do: ""
  defp cell_value(text, %{type: "n"}), do: number(text)
  defp cell_value(text, _string_type), do: text

  # Excel stores 9876543210 as "9876543210" or "9.87654321E+9" and 30 as
  # "30" or "30.0"; phone numbers and PIN codes have to come out whole.
  @doc false
  def number(text) do
    cond do
      text == "" ->
        ""

      Regex.match?(~r/\A-?\d+\.0+\z/, text) ->
        String.replace(text, ~r/\.0+\z/, "")

      Regex.match?(~r/\A-?\d+(\.\d+)?\z/, text) ->
        text

      true ->
        case Float.parse(text) do
          {float, ""} when float == trunc(float) and abs(float) < 1.0e15 ->
            Integer.to_string(trunc(float))

          {float, ""} ->
            :erlang.float_to_binary(float, [:short])

          _not_a_number ->
            text
        end
    end
  end

  # "AB12" => 27 (zero-based).
  defp column_index(ref) when is_binary(ref) do
    case Regex.run(~r/\A([A-Za-z]{1,3})\d*\z/, ref, capture: :all_but_first) do
      [letters] ->
        letters
        |> String.upcase()
        |> String.to_charlist()
        |> Enum.reduce(0, fn char, acc -> acc * 26 + (char - ?A + 1) end)
        |> Kernel.-(1)

      nil ->
        nil
    end
  end

  defp column_index(_missing), do: nil
end
