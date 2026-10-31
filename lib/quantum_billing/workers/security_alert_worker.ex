defmodule QuantumBilling.Workers.SecurityAlertWorker do
  @moduledoc """
  Sends one security alert email.

  Off the request path: an alert raised while someone signs in, or while an
  owner restores a backup, must not wait on — or fail with — the mail relay.
  Retried, because an alert that is lost to a relay hiccup is the one that
  mattered.
  """
  use QuantumBilling.Worker, queue: :mailers, max_attempts: 5

  alias QuantumBilling.Accounts.UserNotifier

  @impl QuantumBilling.Worker
  def process(%Oban.Job{args: %{"to" => to, "subject" => subject, "body" => body}}) do
    case UserNotifier.deliver_security_alert(to, subject, body) do
      {:ok, _email} -> :ok
      {:error, reason} -> {:error, "security alert not delivered: #{inspect(reason)}"}
    end
  end
end
