defmodule QuantumBilling.Paging do
  @moduledoc """
  One page of a list query, for the Previous/Next pager.

  Reads one row more than it shows to know if there's a next page, rather than
  counting (pass `count: true` where the total is shown). An empty page past
  the first is re-read at the real last page. Pages are capped at `max_page/0`.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Repo

  @max_page 1_000

  @doc "The furthest page any list will read."
  def max_page, do: @max_page

  @doc """
  Reads one page of `query` ordered by `order`: `%{rows:, page:, per_page:, has_next?:}`.

  Options:
    * `:per_page` - required, already clamped by the caller
    * `:page` - defaults to 1; clamped to `1..max_page/0`
    * `:count` - also return `:total` and `:total_pages`
  """
  def page(query, order, opts) when is_function(order, 1) do
    per_page = Keyword.fetch!(opts, :per_page)
    page = opts |> Keyword.get(:page, 1) |> clamp(1, @max_page)

    if Keyword.get(opts, :count, false) do
      counted_page(query, order, page, per_page)
    else
      look_ahead_page(query, order, page, per_page)
    end
  end

  @doc """
  Keyset paging for the API: `per_page` rows with ids below `before_id` (or the
  newest, for `nil`), newest first. Returns `%{rows:, per_page:, has_next?:}`.
  """
  def keyset(query, before_id, per_page) when is_integer(per_page) and per_page > 0 do
    query = if before_id, do: where(query, [row], row.id < ^before_id), else: query

    rows =
      query
      |> exclude(:order_by)
      |> order_by([row], desc: row.id)
      |> limit(^(per_page + 1))
      |> Repo.all()

    %{rows: Enum.take(rows, per_page), per_page: per_page, has_next?: length(rows) > per_page}
  end

  defp look_ahead_page(query, order, page, per_page) do
    case read(query, order, page, per_page, per_page + 1) do
      [] when page > 1 ->
        last_page = last_page(count(query), per_page)

        if last_page < page,
          do: look_ahead_page(query, order, last_page, per_page),
          else: result([], page, per_page, false)

      rows ->
        result(Enum.take(rows, per_page), page, per_page, length(rows) > per_page)
    end
  end

  defp counted_page(query, order, page, per_page) do
    total = count(query)
    total_pages = last_page(total, per_page)
    page = min(page, total_pages)

    query
    |> read(order, page, per_page, per_page)
    |> result(page, per_page, page < total_pages)
    |> Map.merge(%{total: total, total_pages: total_pages})
  end

  defp read(query, order, page, per_page, limit) do
    query
    |> order.()
    |> limit(^limit)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  defp result(rows, page, per_page, has_next?) do
    %{rows: rows, page: page, per_page: per_page, has_next?: has_next? and page < @max_page}
  end

  defp count(query), do: Repo.aggregate(query, :count, :id)

  defp last_page(total, per_page),
    do: total |> Kernel./(per_page) |> ceil() |> clamp(1, @max_page)

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum
end
