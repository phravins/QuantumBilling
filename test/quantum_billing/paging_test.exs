defmodule QuantumBilling.PagingTest do
  use QuantumBilling.DataCase, async: true

  import Ecto.Query

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Paging

  defp insert_clients(count) do
    now = DateTime.utc_now(:second)

    rows =
      for n <- 1..count do
        %{name: "Client #{n}", client_type: "Unregistered", inserted_at: now, updated_at: now}
      end

    Repo.insert_all(Client, rows)
  end

  defp by_id(query), do: order_by(query, [c], asc: c.id)

  defp page(opts), do: Paging.page(Client, &by_id/1, opts)

  test "an empty list is one empty page with nothing after it" do
    assert %{rows: [], page: 1, has_next?: false} = page(page: 1, per_page: 10)
    assert %{rows: [], page: 1, has_next?: false} = page(page: 7, per_page: 10)
  end

  test "looks one row ahead at the boundary" do
    insert_clients(10)

    assert %{has_next?: true} = page(per_page: 9)
    assert %{has_next?: false} = page(per_page: 10)
    assert length(page(per_page: 9).rows) == 9
  end

  test "a page past the end falls back to the last real page" do
    insert_clients(7)

    assert %{page: 3, rows: [_], has_next?: false} = page(page: 40, per_page: 3)
  end

  test "a page that isn't a number is the first page" do
    insert_clients(3)

    assert %{page: 1} = page(page: "9", per_page: 2)
    assert %{page: 1} = page(page: nil, per_page: 2)
  end

  test "stops at the furthest page however many rows remain" do
    insert_clients(Paging.max_page() + 1)

    assert %{page: page, rows: [_], has_next?: false} = page(page: 10_000_000, per_page: 1)
    assert page == Paging.max_page()
  end

  test "counts only when asked to" do
    insert_clients(5)

    refute Map.has_key?(page(per_page: 2), :total)
    assert %{total: 5, total_pages: 3, page: 3} = page(page: 9, per_page: 2, count: true)
  end
end
