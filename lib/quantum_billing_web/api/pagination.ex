defmodule QuantumBillingWeb.API.Pagination do
  @moduledoc """
  `page` and `per_page` from a list request.

  `per_page` defaults to 25 and is capped at 100: a single call cannot pull a
  whole table, so a leaked key has to page — slowly, under the rate limit —
  through anything it wants.
  """

  @default_per_page 25
  @max_per_page 100

  @doc "`{:ok, page, per_page}` or `{:error, fields}`."
  def parse(params) do
    with {:ok, page} <- positive(params, "page", 1),
         {:ok, per_page} <- positive(params, "per_page", @default_per_page) do
      if per_page > @max_per_page do
        {:error, %{"per_page" => ["must be at most #{@max_per_page}"]}}
      else
        {:ok, page, per_page}
      end
    end
  end

  @doc """
  The page the context returned, made honest about a page past the end.

  The contexts clamp an out-of-range page to the last one, which suits a screen
  but would loop an integration forever: asking for page 6 of 5 and getting
  page 5 again looks like more data. Past the end, the API returns no rows.
  """
  def settle(%{page: served} = page, requested) when requested > served,
    do: %{page | rows: [], page: requested}

  def settle(page, _requested), do: page

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
