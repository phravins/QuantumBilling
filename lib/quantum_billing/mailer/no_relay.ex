defmodule QuantumBilling.Mailer.NoRelay do
  @moduledoc """
  The app mailer in production when `SMTP_HOST` is not set.

  Every delivery fails with `:no_relay`, which `QuantumBilling.Mail` turns
  into a message saying how to fix it. A business with its own relay
  (Settings > SMTP) still sends: that relay replaces this adapter per message.

  Without it, prod would fall back to `Swoosh.Adapters.Local`, whose storage
  process does not run there (`config :swoosh, local: false`), and every send
  would crash the caller with `:noproc`.
  """

  use Swoosh.Adapter

  @impl Swoosh.Adapter
  def deliver(%Swoosh.Email{}, _config), do: {:error, :no_relay}
end
