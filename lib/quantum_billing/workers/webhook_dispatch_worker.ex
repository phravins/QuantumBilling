defmodule QuantumBilling.Workers.WebhookDispatchWorker do
  @moduledoc """
  The webhook worker before endpoints had their own table, kept only so jobs
  it queued before an upgrade are not lost.

  Such a job carries `{"event", "payload"}`. It is handed to
  `QuantumBilling.Webhooks.publish/3`, which records it as a delivery to
  whichever endpoints subscribe — the endpoint carried over from the old
  setting among them, in the format it always had. Nothing queues this worker
  any more; `QuantumBilling.Workers.WebhookDeliveryWorker` does the sending.
  """
  use QuantumBilling.Worker, queue: :webhooks, max_attempts: 3

  alias QuantumBilling.Webhooks

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: %{"event" => event} = args}) do
    payload = args["payload"] || %{}

    if event in Webhooks.event_types() do
      {:ok, _event_id} = Webhooks.publish(event, payload["invoice_id"], payload)
      :ok
    else
      {:discard, "unknown event #{event}"}
    end
  end

  def process(%Oban.Job{}), do: :discard
end
