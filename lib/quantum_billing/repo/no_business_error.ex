defmodule QuantumBilling.Repo.NoBusinessError do
  @moduledoc """
  A business record was read or written with no business chosen.

  This is a bug in the caller, never a user error: every request, LiveView and
  job that touches a business's records chooses the business first. The likely
  cause is a process spawned without carrying the business across.
  """
  defexception [:message]

  @impl true
  def exception(opts) do
    source =
      case opts[:query] do
        %Ecto.Query{from: %{source: {table, _schema}}} -> " (#{table})"
        _other -> ""
      end

    %__MODULE__{
      message:
        "no business is chosen in this process#{source}. " <>
          "Call QuantumBilling.Repo.put_business/1 or with_business/2 first."
    }
  end
end
