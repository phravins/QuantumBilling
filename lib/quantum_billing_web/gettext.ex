defmodule QuantumBillingWeb.Gettext do
  @moduledoc "The Gettext backend: `use Gettext, backend: QuantumBillingWeb.Gettext`."
  use Gettext.Backend, otp_app: :quantum_billing
end
