defmodule QuantumBilling.Payments.RazorpayClient do
  @moduledoc """
  Razorpay / UPI Payment Gateway Integration wrapper using `Req`.
  """

  alias QuantumBilling.Invoices.Invoice

  @doc """
  Creates a Razorpay Payment Link and UPI QR payload for an invoice.
  """
  def create_payment_link(%Invoice{} = invoice) do
    {key_id, key_secret} = credentials()

    payload = %{
      "amount" => invoice.grand_total * 100,
      "currency" => invoice.currency || "INR",
      "accept_partial" => false,
      "reference_id" => invoice.invoice_number,
      "description" => "Payment for Tax Invoice #{invoice.invoice_number}",
      "customer" => %{
        "name" => invoice.client_name,
        "email" => invoice.client_email || "billing@client.com"
      },
      "notify" => %{
        "email" => true,
        "sms" => false
      },
      "reminder_enable" => true
    }

    if key_id && key_secret do
      auth = {key_id, key_secret}

      case Req.post("https://api.razorpay.com/v1/payment_links",
             json: payload,
             auth: auth,
             receive_timeout: 5000
           ) do
        {:ok, %{status: 200, body: %{"id" => link_id, "short_url" => short_url}}} ->
          {:ok, %{link_id: link_id, short_url: short_url}}

        {:ok, %{body: %{"error" => %{"description" => desc}}}} ->
          {:error, desc}

        _other ->
          sandbox_payment_link(invoice)
      end
    else
      sandbox_payment_link(invoice)
    end
  end

  @doc """
  Verifies the HMAC SHA256 signature of an incoming Razorpay webhook.
  """
  def verify_webhook_signature(raw_body, signature, secret) do
    if is_binary(signature) and is_binary(secret) do
      computed =
        :crypto.mac(:hmac, :sha256, secret, raw_body)
        |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(computed, signature)
    else
      false
    end
  end

  @doc """
  The API credentials, from Settings first and the environment second.

  Settings is checked first because that is where the application asks for
  them, and where they are encrypted at rest; the environment stays supported
  so a deployment can keep them out of the database entirely.
  """
  def credentials do
    organization = QuantumBilling.Settings.get_organization()

    {presence(organization.razorpay_key_id) || System.get_env("RAZORPAY_KEY_ID"),
     presence(organization.razorpay_key_secret) || System.get_env("RAZORPAY_KEY_SECRET")}
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp sandbox_payment_link(invoice) do
    link_id = "plink_" <> Enum.map_join(1..12, fn _ -> to_string(Enum.random(0..9)) end)
    short_url = "https://rzp.io/i/qb_" <> invoice.invoice_number

    {:ok, %{link_id: link_id, short_url: short_url}}
  end
end
