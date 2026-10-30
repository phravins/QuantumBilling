defmodule QuantumBillingWeb.API.V1.MeController do
  @moduledoc """
  The key making the call: its name, scopes and expiry.

  Needs no scope, so an integration can check what it has been granted before
  relying on it. Never returns the key itself or its hash.
  """
  use QuantumBillingWeb, :controller

  def show(conn, _params) do
    key = conn.assigns.api_key

    json(conn, %{
      data: %{
        name: key.name,
        prefix: key.prefix,
        scopes: key.scopes,
        expires_at: key.expires_at,
        created_at: key.inserted_at
      }
    })
  end
end
