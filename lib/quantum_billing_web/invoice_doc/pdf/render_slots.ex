defmodule QuantumBillingWeb.InvoiceDoc.PDF.RenderSlots do
  @moduledoc false
  use GenServer

  @default_limit 2

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def acquire(wait) when is_integer(wait) and wait >= 0 do
    GenServer.call(__MODULE__, {:acquire, wait}, wait + 1_000)
  end

  def release(token), do: GenServer.cast(__MODULE__, {:release, token})

  @impl true
  def init(opts) do
    limit =
      Keyword.get(
        opts,
        :limit,
        Application.get_env(:quantum_billing, :pdf_max_concurrency, @default_limit)
      )

    {:ok, %{limit: limit, active: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:acquire, wait}, {pid, _tag} = from, state) do
    cond do
      map_size(state.active) < state.limit and :queue.is_empty(state.queue) ->
        {token, state} = grant(pid, state)
        {:reply, {:ok, token}, state}

      wait == 0 ->
        {:reply, {:error, :busy}, state}

      true ->
        token = make_ref()
        monitor = Process.monitor(pid)
        timer = Process.send_after(self(), {:expire, token}, wait)
        entry = {token, pid, monitor, from, timer}
        {:noreply, %{state | queue: :queue.in(entry, state.queue)}}
    end
  end

  @impl true
  def handle_cast({:release, token}, state) do
    case Map.pop(state.active, token) do
      {nil, _active} ->
        {:noreply, state}

      {{_pid, monitor}, active} ->
        Process.demonitor(monitor, [:flush])
        {:noreply, promote(%{state | active: active})}
    end
  end

  @impl true
  def handle_info({:expire, token}, state) do
    {entry, queue} = remove_queued(state.queue, token)

    case entry do
      nil ->
        {:noreply, state}

      {_token, _pid, monitor, from, _timer} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, {:error, :busy})
        {:noreply, %{state | queue: queue}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case find_active_monitor(state.active, monitor) do
      nil ->
        {:noreply, %{state | queue: remove_queued_monitor(state.queue, monitor)}}

      token ->
        {_entry, active} = Map.pop(state.active, token)
        {:noreply, promote(%{state | active: active})}
    end
  end

  defp grant(pid, state) do
    token = make_ref()
    monitor = Process.monitor(pid)
    {token, %{state | active: Map.put(state.active, token, {pid, monitor})}}
  end

  defp promote(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, {token, pid, monitor, from, timer}}, queue} ->
        Process.cancel_timer(timer)

        if Process.alive?(pid) do
          GenServer.reply(from, {:ok, token})
          %{state | active: Map.put(state.active, token, {pid, monitor}), queue: queue}
        else
          Process.demonitor(monitor, [:flush])
          promote(%{state | queue: queue})
        end
    end
  end

  defp remove_queued(queue, token) do
    entries = :queue.to_list(queue)

    {removed, kept} =
      Enum.split_with(entries, fn {entry_token, _, _, _, _} ->
        entry_token == token
      end)

    {List.first(removed), :queue.from_list(kept)}
  end

  defp remove_queued_monitor(queue, monitor) do
    entries =
      queue
      |> :queue.to_list()
      |> Enum.reject(fn {_, _, entry_monitor, _, _} -> entry_monitor == monitor end)

    :queue.from_list(entries)
  end

  defp find_active_monitor(active, monitor) do
    Enum.find_value(active, fn {token, {_pid, entry_monitor}} ->
      if entry_monitor == monitor, do: token
    end)
  end
end
