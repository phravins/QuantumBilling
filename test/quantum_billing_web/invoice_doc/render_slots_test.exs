defmodule QuantumBillingWeb.InvoiceDoc.RenderSlotsTest do
  use ExUnit.Case, async: false

  alias QuantumBillingWeb.InvoiceDoc.PDF.RenderSlots

  @limit Application.compile_env(:quantum_billing, :pdf_max_concurrency, 2)

  defp acquire_all_slots do
    Enum.map(1..@limit, fn _ ->
      assert {:ok, token} = RenderSlots.acquire(0)
      token
    end)
  end

  defp wait_for_queue(size, attempts \\ 50)
  defp wait_for_queue(0, _attempts), do: :ok

  defp wait_for_queue(size, attempts) when attempts > 0 do
    if :queue.len(:sys.get_state(RenderSlots).queue) == size do
      :ok
    else
      Process.sleep(10)
      wait_for_queue(size, attempts - 1)
    end
  end

  test "waits for a render slot and acquires it when released" do
    tokens = acquire_all_slots()

    task = Task.async(fn -> RenderSlots.acquire(2_000) end)

    try do
      wait_for_queue(1)
      RenderSlots.release(hd(tokens))

      assert {:ok, acquired_token} = Task.await(task, 3_000)
      RenderSlots.release(acquired_token)
    after
      Task.shutdown(task, :brutal_kill)
      Enum.each(tokens, &RenderSlots.release/1)
    end
  end

  test "returns busy when no render slot becomes available in time" do
    tokens = acquire_all_slots()

    try do
      assert {:error, :busy} = RenderSlots.acquire(25)
    after
      Enum.each(tokens, &RenderSlots.release/1)
    end
  end
end
