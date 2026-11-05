defmodule QuantumBillingWeb.ConnCase do
  @moduledoc """
  Case template for tests that need a connection. Uses the SQL sandbox, so
  `async: true` is safe.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint QuantumBillingWeb.Endpoint

      use QuantumBillingWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import QuantumBillingWeb.ConnCase
    end
  end

  setup tags do
    QuantumBilling.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup: logs in a staff user. Adds `conn`, `user` and `scope` to the context.

      setup :register_and_log_in_user
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = QuantumBilling.AccountsFixtures.user_fixture()
    scope = QuantumBilling.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Setup: logs in the installation owner, for owner-only pages (credential
  panels, Team, full export). Staff stays the default.

      setup :register_and_log_in_owner
  """
  def register_and_log_in_owner(%{conn: conn} = context) do
    user = QuantumBilling.AccountsFixtures.owner_fixture()
    scope = QuantumBilling.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc "Logs `user` into `conn` and returns the conn."
  def log_in_user(conn, user, opts \\ []) do
    token = QuantumBilling.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:business_id, opts[:business_id] || 1)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    QuantumBilling.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
