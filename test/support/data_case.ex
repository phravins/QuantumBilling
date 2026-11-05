defmodule QuantumBilling.DataCase do
  @moduledoc """
  Case template for data-layer tests. Uses the SQL sandbox, so `async: true`
  is safe.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias QuantumBilling.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import QuantumBilling.DataCase
    end
  end

  setup tags do
    QuantumBilling.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Starts the sandbox from the test tags and selects business 1. Switch with
  `Repo.with_business/2` or `put_business/1`.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(QuantumBilling.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    QuantumBilling.Repo.put_business(QuantumBilling.Businesses.default!())
  end

  @doc """
  Changeset errors as a map of messages.

      assert %{password: ["password is too short"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
