defmodule QuantumBillingWeb.API.Pagination do
  @moduledoc """
  `page` and `per_page` from a list request, and the `meta` a list returns.

  `per_page` defaults to 25 and is capped at 100: a single call cannot pull a
  whole table, so a leaked key has to page — slowly, under the rate limit —
  through anything it wants.

  Lists are read the way the screens read them (`QuantumBilling.Paging`): one
  row past the page tells whether there is a next one, and nothing is counted.
  So `meta` says `has_next` rather than a total. Pages stop at
  `Paging.max_page/0`, as on the screens; past that, narrow with `search` or
  `status`.
  """

  alias QuantumBilling.Paging

  @default_per_page 25
  @max_per_page 100

  @doc "`{:ok, page, per_page}` or `{:error, fields}`."
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
  def settle(%{page: served} = page, requested) when requested > served,
    do: %{page | rows: [], page: requested, has_next?: false}

  def settle(page, _requested), do: page

  @doc "The `meta` object of a list response."
  def meta(page), do: %{page: page.page, per_page: page.per_page, has_next: page.has_next?}

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
