defmodule QuantumBillingWeb.DocumentForm do
  @moduledoc """
  Client-picker and line helpers the invoice and quotation forms share.

  The LiveView keeps `:client_search`, `:selected_client_id`, `:gstin_hint`,
  `:clients` and `:client_options_truncated?` in its assigns. Picking a client,
  or typing its exact name, copies its details once; they stay editable.
  """
  import Phoenix.Component, only: [assign: 3]

  alias QuantumBilling.Clients
  alias QuantumBilling.GST
  alias QuantumBilling.Invoices

  @doc "Assigns the empty client-picker state."
  def init_client_picker(socket, selected_client_id \\ nil, client \\ nil) do
    socket
    |> assign(:client_search, "")
    |> assign(:selected_client_id, selected_client_id)
    |> assign(:gstin_hint, gstin_hint(client))
    |> assign_client_options()
  end

  @doc "Refreshes the picker options for the current search."
  def assign_client_options(socket) do
    options =
      Clients.picker_options(socket.assigns.client_search, socket.assigns.selected_client_id)

    socket
    |> assign(:clients, options)
    |> assign(:client_options_truncated?, length(options) >= Clients.picker_limit())
  end

  @doc "Handles the picker's search box."
  def search_clients(socket, search) do
    socket |> assign(:client_search, search) |> assign_client_options()
  end

  @doc """
  Copies the client's details only when the choice changes, so edits survive.
  The previous choice is kept server-side, not in a hidden input.
  """
  def apply_client_choice(params, socket) do
    id = params["client_id"]

    # From the database: the client may no longer be in the picker's results.
    client = id not in [nil, ""] && Clients.get_client(id)

    cond do
      client && to_string(id) != to_string(socket.assigns.selected_client_id) ->
        {copy_client(params, client),
         socket
         |> assign(:selected_client_id, id)
         |> assign(:gstin_hint, gstin_hint(client))
         |> assign_client_options()}

      id == "" and socket.assigns.selected_client_id != nil ->
        {params, socket |> assign(:selected_client_id, nil) |> assign(:gstin_hint, nil)}

      true ->
        {params, socket}
    end
  end

  # `client_id` stays a string so the picker comparisons work; the rest is the shared API snapshot.
  defp copy_client(params, client) do
    Map.merge(params, Map.delete(Invoices.client_snapshot(client), "client_id"))
  end

  @doc """
  A typed name that exactly matches a client selects that client, but only when
  the name box itself (`[form_name, "client_name"]`) changed.
  """
  def match_typed_client(params, [form_name, "client_name"], form_name) do
    case Clients.get_client_by_name(params["client_name"]) do
      nil -> params
      client -> Map.put(params, "client_id", to_string(client.id))
    end
  end

  def match_typed_client(params, _other_target, _form_name), do: params

  @doc "Fills an empty PAN from the GSTIN (characters 3-12); never overwrites one."
  def pan_from_gstin(params) do
    gstin = params |> Map.get("client_gstin") |> to_string() |> String.trim() |> String.upcase()

    case {present(params["client_pan"]), GST.pan_from_gstin(gstin)} do
      {nil, pan} when is_binary(pan) -> Map.put(params, "client_pan", pan)
      _typed_or_no_gstin -> params
    end
  end

  @doc "A hint under GSTIN when the chosen client has none on file."
  def gstin_hint(%Clients.Client{} = client) do
    if present(client.gstin) == nil do
      "No GSTIN on file for this client (#{client.client_type})."
    end
  end

  def gstin_hint(_no_client), do: nil

  @doc "The params of an empty line at `position`."
  def blank_item(position) do
    %{
      "description" => "",
      "quantity" => "1",
      "unit" => "Nos",
      "rate" => "0",
      "tax_rate" => "18",
      "position" => to_string(position)
    }
  end

  @doc "A trimmed string, or `nil` when blank."
  def present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def present(_value), do: nil
end
