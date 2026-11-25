defmodule QuantumBilling.Payments.WebhookSecretTest do
  # Not async: it sets RAZORPAY_WEBHOOK_SECRET, which the whole VM shares.
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Businesses
  alias QuantumBilling.Payments

  setup do
    previous = System.get_env("RAZORPAY_WEBHOOK_SECRET")
    System.put_env("RAZORPAY_WEBHOOK_SECRET", "whsec_server_wide")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("RAZORPAY_WEBHOOK_SECRET")
        value -> System.put_env("RAZORPAY_WEBHOOK_SECRET", value)
      end
    end)

    {:ok, other} =
      Businesses.create(QuantumBilling.AccountsFixtures.owner_fixture(), %{"name" => "Firm Two"})

    %{other: other}
  end

  defp put_webhook_secret(secret) do
    QuantumBilling.Settings.ensure_organization()
    |> Ecto.Changeset.change(razorpay_webhook_secret: secret)
    |> Repo.update!()
  end

  test "the first business falls back to the server-wide secret" do
    assert {:ok, "whsec_server_wide"} = Payments.webhook_secret(Businesses.default!())
  end

  test "the first business's own secret replaces the server-wide one" do
    put_webhook_secret("whsec_first")

    assert {:ok, "whsec_first"} = Payments.webhook_secret(Businesses.default!())
  end

  test "any other business has only its own", %{other: other} do
    assert {:error, :not_configured} = Payments.webhook_secret(other)

    Repo.with_business(other, fn -> put_webhook_secret("whsec_other") end)

    assert {:ok, "whsec_other"} = Payments.webhook_secret(other)
  end
end
