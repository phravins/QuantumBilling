defmodule QuantumBilling.AuditPageTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit

  setup do
    for n <- 1..30 do
      {:ok, _log} =
        Audit.log_event(
          if(rem(n, 3) == 0, do: :payment_received, else: :generate_irn),
          "Invoice",
          n
        )
    end

    :ok
  end

  test "pages the trail newest first" do
    result = Audit.page(page: 1, per_page: 10)

    assert length(result.rows) == 10
    assert result.total == 30
    assert result.total_pages == 3
  end

  test "filters by action across the whole trail, not just the newest page" do
    result = Audit.page(action: "payment_received", per_page: 5)

    assert result.total == 10
    assert Enum.all?(result.rows, &(&1.action == "payment_received"))
  end

  test "an empty filter means everything" do
    assert Audit.page(action: "").total == 30
    assert Audit.page(action: nil).total == 30
  end

  test "lists the actions actually present, for the filter control" do
    assert Audit.actions() == ["generate_irn", "payment_received"]
  end

  test "clamps the page past the end" do
    assert Audit.page(page: 99, per_page: 10).page == 3
  end
end
