defmodule QuantumBillingWeb.API.Pagination do
  @moduledoc """
  `page` and `per_page` from a list request, and the `meta` a list returns.

  `per_page` defaults to 25 and is capped at 100: a single call cannot pull a
  whole table, so a leaked key has to page — slowly, under the rate limit —
  through anything it wants.

  Lists are read the way the screens read them (`QuantumBilling.Paging`): one
  row past the page tells whether there is a next one, and nothing is counted.
  So `meta` says `has_next` rather than a total. Pages stop at
  `Paging.max_page/0`, as on the screens.

  Cursor mode (`paginate=cursor`, then the `next_cursor` each response gives)
  pages newest-created first with no depth limit and no drift when records
  are added mid-way; it is what a sync job should use.
  """

  alias QuantumBilling.Paging

  @default_per_page 25
  @max_per_page 100

  @doc """
  The paging a list request asked for:

    * `{:ok, {:cursor, before_id}, per_page}` — cursor mode, entered with
      `paginate=cursor` (`before_id` nil: from the newest) or by passing a
      `cursor` from a previous response;
    * `{:ok, page, per_page}` — numbered pages;
    * `{:error, fields}`.
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
  The page the context returned, made honest about a page past the end.

  `Paging` answers a page past the end with the last page instead, which suits
  a screen but would loop an integration forever: asking for page 6 of 5 and
  getting page 5 again looks like more data. Past the end, the API returns no
  rows.
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
