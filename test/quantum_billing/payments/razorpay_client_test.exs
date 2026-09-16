defmodule QuantumBilling.Payments.RazorpayClientTest do
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.RazorpayClient
  alias QuantumBilling.Settings

  defp invoice do
    %Invoice{
      invoice_number: "INV-4001",
      invoice_date: ~D[2026-03-01],
      client_name: "Acme Corp",
      client_email: "billing@acme.test",
      grand_total: 11_800,
      currency: "INR"
    }
  end

  defp without_sandbox(fun) do
    previous = Application.get_env(:quantum_billing, :razorpay_sandbox)
    Application.put_env(:quantum_billing, :razorpay_sandbox, false)

    try do
      fun.()
    after
      Application.put_env(:quantum_billing, :razorpay_sandbox, previous)
    end
  end

  describe "create_payment_link/1 without credentials" do
    test "refuses, rather than inventing a link that leads nowhere" do
      without_sandbox(fn ->
        assert {:error, message} = RazorpayClient.create_payment_link(invoice())

        # The old behaviour was to answer every failure with a fabricated
        # `plink_…` id and an `rzp.io` URL that does not exist, record it on
        # the invoice, and report success.
        assert message =~ "not configured"
        refute RazorpayClient.configured?()
      end)
    end

    test "simulates one only where simulation is switched on" do
      assert RazorpayClient.sandbox?()

      assert {:ok, %{link_id: link_id, short_url: url}} =
               RazorpayClient.create_payment_link(invoice())

      # Recognisable as simulated wherever it turns up later.
      assert link_id =~ "plink_sandbox_"
      assert url =~ "sandbox"
      assert RazorpayClient.configured?()
    end
  end

  describe "credentials/0" do
    test "prefers the encrypted settings over the environment" do
      System.put_env("RAZORPAY_KEY_ID", "rzp_from_env")
      System.put_env("RAZORPAY_KEY_SECRET", "secret_from_env")
      on_exit(fn -> System.delete_env("RAZORPAY_KEY_ID") end)
      on_exit(fn -> System.delete_env("RAZORPAY_KEY_SECRET") end)

      assert {"rzp_from_env", "secret_from_env"} = RazorpayClient.credentials()

      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{
            "razorpay_key_id" => "rzp_from_settings",
            "razorpay_key_secret" => "secret_from_settings"
          },
          :integrations
        )

      assert {"rzp_from_settings", "secret_from_settings"} = RazorpayClient.credentials()
    end
  end

  describe "verify_webhook_signature/3" do
    test "accepts only an exact match over the raw body" do
      body = ~s({"event":"payment.captured"})
      signature = :hmac |> :crypto.mac(:sha256, "shhh", body) |> Base.encode16(case: :lower)

      assert RazorpayClient.verify_webhook_signature(body, signature, "shhh")
      refute RazorpayClient.verify_webhook_signature(body <> " ", signature, "shhh")
      refute RazorpayClient.verify_webhook_signature(body, signature, "other")
      refute RazorpayClient.verify_webhook_signature(body, nil, "shhh")
    end
  end
end
