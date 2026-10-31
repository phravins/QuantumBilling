defmodule QuantumBillingWeb.DependencyFloorTest do
  @moduledoc """
  The versions below which a dependency has a known, published vulnerability
  that reaches this application. A downgrade — a stale lockfile, a careless
  `mix deps.update` — fails here instead of shipping.

  Raise a floor when a new advisory lands; never lower one without the
  advisory being withdrawn.
  """
  use ExUnit.Case, async: true

  @floors [
    # The web server. HTTP/1.1 chunked and HTTP/2 frame amplification,
    # request smuggling, WebSocket fragment bypass (October 2026).
    {:bandit, "1.14.1"},
    # Channel joins per transport (GHSA-6983-jfq8-485w), LongPoll NDJSON
    # allocation (GHSA-628h-q48j-jr6q).
    {:phoenix, "1.8.9"},
    # <.link> scheme bypass (GHSA-5cgh-g58j-m9cq), redirect via tab/CR/LF
    # (GHSA-36m4-rm57-3prf).
    {:phoenix_live_view, "1.2.9"},
    # HPACK decode amplification (GHSA-jj2p-32j7-whj2).
    {:hpax, "1.0.4"}
  ]

  for {app, floor} <- @floors do
    test "#{app} is at least #{floor}" do
      version = unquote(app) |> Application.spec(:vsn) |> to_string()

      assert Version.compare(version, unquote(floor)) != :lt,
             "#{unquote(app)} #{version} is below #{unquote(floor)}, which has a published vulnerability"
    end
  end
end
