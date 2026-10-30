defmodule QuantumBillingWeb.LogFilteringTest do
  @moduledoc """
  What request logging scrubs.

  Phoenix's default filter is `["password"]` alone. Everything here is a
  credential or a bearer token that was previously written to the log in clear
  at debug level.
  """
  use ExUnit.Case, async: true

  @filtered "[FILTERED]"

  defp filter(params), do: Phoenix.Logger.filter_values(params)

  test "scrubs every kind of credential this application receives" do
    params = %{
      "user" => %{"password" => "hunter2", "recovery_code" => "ab12-cd34", "code" => "123456"},
      "token" => "invitation-token",
      "organization" => %{
        "smtp_password" => "smtp-pass",
        "webhook_secret" => "whsec",
        "razorpay_key_secret" => "rzp-secret"
      },
      "api_key" => "qb_live_x",
      "authorization" => "Bearer qb_live_x"
    }

    filtered = filter(params)

    assert filtered["user"]["password"] == @filtered
    assert filtered["user"]["recovery_code"] == @filtered
    assert filtered["user"]["code"] == @filtered
    assert filtered["token"] == @filtered
    assert filtered["organization"]["smtp_password"] == @filtered
    assert filtered["organization"]["webhook_secret"] == @filtered
    assert filtered["organization"]["razorpay_key_secret"] == @filtered
    assert filtered["api_key"] == @filtered
    assert filtered["authorization"] == @filtered
  end

  test "leaves ordinary business fields readable" do
    params = %{
      "client_name" => "Acme",
      "invoice_date" => "2026-10-01",
      "place_of_supply" => "Kerala"
    }

    # Over-filtering makes logs useless for the debugging they exist for.
    # (`*_code` fields are the accepted exception: "code" is filtered for 2FA.)
    assert filter(params) == params
  end
end
