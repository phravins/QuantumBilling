defmodule QuantumBilling.FakeDNS do
  @moduledoc """
  The resolver `QuantumBilling.Webhooks.UrlGuard` uses in tests.

  Test hosts (`*.example.test`, `*.example.com`) do not resolve on most
  machines, and a test must not depend on real DNS. So:

    * an IP literal resolves to itself;
    * `localhost` to loopback;
    * a name registered with `put/2` to what it was given — how a test stages
      a rebinding attack, a name that turns private;
    * anything else to one fixed public address (documentation range).
  """

  @public {203, 0, 113, 10}

  @doc "Makes `host` resolve to `addresses` for the rest of the test run."
  def put(host, addresses), do: :persistent_term.put({__MODULE__, host}, addresses)

  @doc "The address unregistered names resolve to."
  def public_address, do: @public

  def resolve_with_dns(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        [address]

      {:error, _not_literal} ->
        cond do
          host == "localhost" -> [{127, 0, 0, 1}]
          addresses = :persistent_term.get({__MODULE__, host}, nil) -> addresses
          true -> [@public]
        end
    end
  end
end
