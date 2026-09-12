defmodule QuantumBilling.Workers.RecurringInvoiceWorkerTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Workers.RecurringInvoiceWorker

  test "perform/1 executes Oban job successfully" do
    assert {:ok, result} = RecurringInvoiceWorker.perform(%Oban.Job{})
    assert is_integer(result.processed_count)
  end
end
