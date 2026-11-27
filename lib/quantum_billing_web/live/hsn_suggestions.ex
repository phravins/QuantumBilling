defmodule QuantumBillingWeb.HsnSuggestions do
  @moduledoc """
  HSN/SAC suggestions on the invoice and quotation item rows (GST only).

  The state lives in one assign, `:hsn`, read by
  `DocumentFormComponents.items_section/1`:

    * `open` and `list`: the row whose suggestions are showing, and them.
      Typing a description suggests from `HsnFinder.suggest/2` (the
      business's own history first, then the catalogue); typing digits in
      the HSN/SAC box suggests codes under that prefix.
    * `lookup`: the row whose "Find HSN/SAC" search is open, and its query.
    * `suggested`: rows whose code was filled from a suggestion and not yet
      edited by hand; they carry a "Suggested" tag.
    * `manual`: rows whose code or rate was typed by hand in this session.
    * `notice`: the "please verify" note after a pick, for a few seconds.

  Picking a suggestion asks first (`data-confirm`, see `confirm_pick?/5`)
  when it would replace a code or GST rate that did not come from a
  suggestion: typed by hand, saved on the document or copied from a
  quotation. So nothing the user chose is replaced without them saying so.

  Adding or removing a row closes the panel and carries the manual and
  suggested flags to each surviving row's new index.
  """

  import Phoenix.Component, only: [assign: 3]

  alias QuantumBilling.HsnFinder
  alias QuantumBilling.Settings.Organization
  alias QuantumBillingWeb.DocumentForm

  @notice_ms 6_000

  # Below this many letters a description says too little to match.
  @min_description 3

  @doc "The starting state. Off (nil) for a VAT business or document."
  def init(socket, vat?) do
    assign(socket, :hsn, if(vat?, do: nil, else: blank()))
  end

  defp blank do
    %{
      open: nil,
      list: [],
      from: nil,
      lookup: nil,
      query: "",
      suggested: MapSet.new(),
      manual: MapSet.new(),
      notice: nil
    }
  end

  @doc """
  Follows a `phx-change` on the document form: `form` is its name
  ("invoice"), `params` its values and `target` the event's `_target`.
  """
  def on_change(%{assigns: %{hsn: nil}} = socket, _form, _params, _target), do: socket

  def on_change(socket, form, params, target) do
    update(socket, fn hsn -> changed(hsn, form, params, target || []) end)
  end

  defp changed(hsn, form, params, [form, "items", index, "description"]) do
    description = get_in(params, ["items", index, "description"]) || ""

    if String.length(String.trim(description)) >= @min_description do
      %{hsn | open: index, from: :description, list: HsnFinder.suggest(description), lookup: nil}
    else
      close(hsn)
    end
  end

  defp changed(hsn, form, params, [form, "items", index, "hsn_sac"]) do
    code = params |> get_in(["items", index, "hsn_sac"]) |> to_string() |> String.trim()

    hsn = %{
      hsn
      | manual: MapSet.put(hsn.manual, index),
        suggested: MapSet.delete(hsn.suggested, index)
    }

    if Regex.match?(~r/^\d{2,}$/, code),
      do: %{hsn | open: index, from: :code, list: HsnFinder.suggest_code(code), lookup: nil},
      else: close(hsn)
  end

  defp changed(hsn, form, _params, [form, "items", index, "tax_rate"]) do
    %{
      hsn
      | manual: MapSet.put(hsn.manual, index),
        suggested: MapSet.delete(hsn.suggested, index)
    }
  end

  # The "Find HSN/SAC" search box.
  defp changed(%{lookup: index} = hsn, _form, params, ["hsn_lookup"]) when is_binary(index) do
    query = params |> Map.get("hsn_lookup", "") |> to_string()
    %{hsn | query: query}
  end

  defp changed(hsn, form, params, [form, key | _rest]) when key in ["items_sort", "items_drop"] do
    # The form sends every existing index in items_sort. Ecto drops the
    # removed indexes and assigns a position to each remaining or new row.
    order = List.wrap(params["items_sort"]) -- List.wrap(params["items_drop"])
    indexes = Enum.with_index(order)

    %{
      blank()
      | manual: reindex(hsn.manual, indexes),
        suggested: reindex(hsn.suggested, indexes)
    }
  end

  defp changed(hsn, _form, _params, _target), do: hsn

  defp reindex(flags, indexes) do
    for {old, new} <- indexes, MapSet.member?(flags, old), into: MapSet.new() do
      Integer.to_string(new)
    end
  end

  @doc "The \"Find HSN/SAC\" search for a row, by keyword or by code."
  def lookup_results(%{query: query}) do
    query = String.trim(query)

    cond do
      query == "" -> []
      Regex.match?(~r/^\d+$/, query) -> HsnFinder.suggest_code(query, limit: 8)
      true -> HsnFinder.suggest(query, history: false, limit: 8)
    end
  end

  @doc "Opens the \"Find HSN/SAC\" search on a row."
  def open_lookup(socket, index) do
    update(socket, &%{close(&1) | lookup: index, query: ""})
  end

  @doc "Closes the suggestions and the search."
  def close_all(socket), do: update(socket, &close/1)

  defp close(hsn), do: %{hsn | open: nil, list: [], from: nil, lookup: nil, query: ""}

  @doc """
  The form params with a picked code and rate on row `index`, and nothing
  else changed. A rate the form does not offer (an old slab from a past
  invoice) is left as it was; only the code is filled.
  """
  def pick_params(params, index, code, rate) do
    item =
      params
      |> get_in(["items", index])
      |> Kernel.||(%{})
      |> Map.put("hsn_sac", code)
      |> put_rate(rate)

    put_in(params, [Access.key("items", %{}), index], item)
  end

  defp put_rate(item, rate) do
    case applied_rate(rate) do
      nil -> item
      rate -> Map.put(item, "tax_rate", rate)
    end
  end

  # The rate a pick puts on the row, as the form sends it ("18"), or nil
  # when the form does not offer it and the row keeps its own.
  defp applied_rate(rate) do
    rate = to_string(rate)
    if rate in Enum.map(Organization.gst_rates(), &to_string/1), do: rate
  end

  @doc """
  Whether picking `option` on row `index` asks first. `code` and `rate` are
  the row's values as they are now.

  It asks when the pick would replace a code or GST rate that did not come
  from a suggestion: one typed by hand in this session (the row is in
  `manual`), or one already on the row when the form opened (saved on the
  document, copied from a quotation, restored after a reconnect). It does
  not ask on a row filled from a suggestion and not edited since, nor on a
  new row whose rate is still the default.
  """
  def confirm_pick?(hsn, index, code, rate, option) do
    cond do
      MapSet.member?(hsn.suggested, index) -> false
      MapSet.member?(hsn.manual, index) -> true
      true -> replaces_code?(code, option) or replaces_rate?(rate, option)
    end
  end

  defp replaces_code?(code, option) do
    code = code |> to_string() |> String.trim()
    code != "" and code != option.code
  end

  defp replaces_rate?(rate, option) do
    rate = to_string(rate)
    new_rate = applied_rate(option.rate)

    new_rate != nil and new_rate != rate and rate not in ["", default_rate()]
  end

  # What a new line starts with; a row still on it has no rate of its own.
  defp default_rate, do: DocumentForm.blank_item(0)["tax_rate"]

  @doc "The question `data-confirm` asks before a pick replaces a row's values."
  def confirm_message(option) do
    type = option.type |> to_string() |> String.upcase()

    case applied_rate(option.rate) do
      nil ->
        "This line already has its own HSN/SAC or GST rate. " <>
          "Use #{type} #{option.code} instead? The GST rate stays as it is."

      rate ->
        "This line already has its own HSN/SAC or GST rate. " <>
          "Replace them with #{type} #{option.code} at #{rate}%?"
    end
  end

  @doc """
  Marks a row as filled from a suggestion and shows the "please verify"
  note for a few seconds.
  """
  def picked(socket, index, code, rate) do
    Process.send_after(self(), {:clear_hsn_notice, index}, @notice_ms)

    type = code |> HsnFinder.code_type() |> to_string() |> String.upcase()

    update(socket, fn hsn ->
      %{
        close(hsn)
        | suggested: MapSet.put(hsn.suggested, index),
          manual: MapSet.delete(hsn.manual, index),
          notice:
            {index,
             "Suggested #{type} #{code} at #{rate}% — please verify against your product classification."}
      }
    end)
  end

  @doc "Clears the note, unless a later pick has replaced it."
  def clear_notice(socket, index) do
    update(socket, fn
      %{notice: {^index, _text}} = hsn -> %{hsn | notice: nil}
      hsn -> hsn
    end)
  end

  defp update(%{assigns: %{hsn: nil}} = socket, _fun), do: socket
  defp update(socket, fun), do: assign(socket, :hsn, fun.(socket.assigns.hsn))
end
