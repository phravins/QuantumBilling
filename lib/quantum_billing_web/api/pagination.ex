defmodule QuantumBillingWeb.API.Pagination do
  @moduledoc """
  `page` and `per_page` from a list request, and the `meta` a list returns.

  `per_page` defaults to 25, max 100. Numbered pages report `has_next` (no
  total) and stop at `Paging.max_page/0`. Cursor mode (`paginate=cursor`, then
  `next_cursor`) pages newest first with no depth limit; sync jobs should use it.
  """

  alias QuantumBilling.Paging

  @default_per_page 25
  @max_per_page 100

  @doc """
  The paging a list request asked for:

    * `{:ok, {:cursor, before_id}, per_page}` - cursor mode (`before_id` nil means newest)
    * `{:ok, page, per_page}` - numbered pages
    * `{:error, fields}`
  """
  def parse(%{"cursor" => cursor} = params) when is_binary(cursor) do
    with {:ok, before_id} <- decode_cursor(cursor),
         {:ok, per_page} <- per_page(params) do
      {:ok, {:cursor, before_id}, per_page}
    end
  end

  def parse(%{"paginate" => "cursor"} = params) do
    with {:ok, per_page} <- per_page(params), do: {:ok, {:cursor, nil}, per_page}
  end

  def parse(params) do
    with {:ok, page} <- positive(params, "page", 1),
         {:ok, per_page} <- positive(params, "per_page", @default_per_page) do
      cond do
        per_page > @max_per_page ->
          {:error, %{"per_page" => ["must be at most #{@max_per_page}"]}}

        # Refused rather than quietly served as the last page: an integration
        # walking pages would otherwise never see the end.
        page > Paging.max_page() ->
          {:error, %{"page" => ["must be at most #{Paging.max_page()}"]}}

        true ->
          {:ok, page, per_page}
      end
    end
  end

  @doc """
  The page from the context, but empty past the end (`Paging` would return the last page again).
  """
  def settle(%{page: served} = page, requested) when is_integer(requested) and requested > served,
    do: %{page | rows: [], page: requested, has_next?: false}

  def settle(page, _requested), do: page

  @doc """
  The context options for what `parse/1` returned, on top of `opts`.
  """
  def context_opts({:cursor, before_id}, per_page, opts),
    do: opts ++ [keyset: true, before_id: before_id, per_page: per_page]

  def context_opts(page, per_page, opts), do: opts ++ [page: page, per_page: per_page]

  @doc "The `meta` object of a list response."
  def meta(%{page: page} = result),
    do: %{page: page, per_page: result.per_page, has_next: result.has_next?}

  # Cursor mode: the cursor for the next page, or nil at the end.
  def meta(result) do
    next =
      if result.has_next?,
        do: result.rows |> List.last() |> Map.fetch!(:id) |> encode_cursor(),
        else: nil

    %{per_page: result.per_page, has_next: result.has_next?, next_cursor: next}
  end

  # Opaque to callers: a version and the last id, so the format can change
  # without old cursors silently meaning something else.
  defp encode_cursor(id), do: Base.url_encode64("v1:#{id}", padding: false)

  defp decode_cursor(cursor) do
    with {:ok, "v1:" <> id} <- Base.url_decode64(cursor, padding: false),
         {id, ""} when id > 0 <- Integer.parse(id) do
      {:ok, id}
    else
      _invalid -> {:error, %{"cursor" => ["is not a cursor this API returned"]}}
    end
  end

  defp per_page(params) do
    with {:ok, per_page} <- positive(params, "per_page", @default_per_page) do
      if per_page > @max_per_page,
        do: {:error, %{"per_page" => ["must be at most #{@max_per_page}"]}},
        else: {:ok, per_page}
    end
  end

  defp positive(params, name, default) do
    case Map.get(params, name) do
      nil ->
        {:ok, default}

      value ->
        case Integer.parse(to_string(value)) do
          {int, ""} when int > 0 -> {:ok, int}
          _other -> {:error, %{name => ["must be a positive whole number"]}}
        end
    end
  end
end
