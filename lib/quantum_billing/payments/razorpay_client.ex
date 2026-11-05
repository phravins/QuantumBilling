defmodule QuantumBilling.Payments.RazorpayClient do
  @moduledoc """
  Razorpay payment links, and the signature check for their webhooks.

  Failures return `{:error, reason}`; simulated links exist only when
  `:razorpay_sandbox` is on and are labelled as such in their id. Credentials
  come from Settings › Integrations first, then the environment.
  """

  require Logger

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings

  @endpoint "https://api.razorpay.com/v1/payment_links"
  @receive_timeout 10_000

  @doc """
  Creates a payment link for an invoice: `{:ok, %{link_id:, short_url:}}` or `{:error, message}`.
  """
  def create_payment_link(%Invoice{} = invoice) do
    case credentials() do
      {key_id, key_secret} when is_binary(key_id) and is_binary(key_secret) ->
        request(invoice, key_id, key_secret)

      _missing ->
        if sandbox?() do
          sandbox_payment_link(invoice)
        else
          {:error,
           "Razorpay is not configured — add the key id and secret in Settings › Integrations."}
        end
    end
  end

  defp request(%Invoice{} = invoice, key_id, key_secret) do
    case Req.post(@endpoint,
           json: payload(invoice),
           auth: {:basic, "#{key_id}:#{key_secret}"},
           receive_timeout: @receive_timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: %{"id" => link_id, "short_url" => short_url}}}
      when status in 200..299 ->
        {:ok, %{link_id: link_id, short_url: short_url}}

      {:ok, %{status: 401}} ->
        {:error, "Razorpay rejected the API key. Check the key id and secret in Settings."}

      {:ok, %{body: %{"error" => %{"description" => description}}}} ->
        {:error, "Razorpay refused the request: #{description}"}

      {:ok, %{status: status}} ->
        {:error, "Razorpay returned HTTP #{status}."}

      {:error, exception} ->
        Logger.warning("[Razorpay] #{Exception.message(exception)}")
        {:error, "Could not reach Razorpay: #{Exception.message(exception)}"}
    end
  end

  defp payload(%Invoice{} = invoice) do
    %{
      # Razorpay counts in paise, as the invoice does.
      "amount" => invoice.grand_total || 0,
      "currency" => invoice.currency || "INR",
      "accept_partial" => false,
      "reference_id" => invoice.invoice_number,
      "description" =>
        "Payment for #{invoice.invoice_type || "Tax Invoice"} #{invoice.invoice_number}",
      "customer" => customer(invoice),
      "notify" => %{"email" => invoice.client_email not in [nil, ""], "sms" => false},
      "reminder_enable" => true,
      "notes" => %{"invoice_number" => invoice.invoice_number}
    }
  end

  # Razorpay rejects placeholder contact details.
  defp customer(%Invoice{} = invoice) do
    %{"name" => invoice.client_name}
    |> maybe_put("email", invoice.client_email)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Verifies a Razorpay webhook's HMAC-SHA256 signature, in constant time."
  def verify_webhook_signature(raw_body, signature, secret)
      when is_binary(raw_body) and is_binary(signature) and is_binary(secret) do
    computed =
      :hmac
      |> :crypto.mac(:sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(computed, signature)
  end

  def verify_webhook_signature(_raw_body, _signature, _secret), do: false

  @doc "The API credentials: Settings first (encrypted), then the environment."
  def credentials do
    organization = Settings.get_organization()

    {presence(organization.razorpay_key_id) || presence(System.get_env("RAZORPAY_KEY_ID")),
     presence(organization.razorpay_key_secret) || presence(System.get_env("RAZORPAY_KEY_SECRET"))}
  end

  @doc """
  Whether payment links can be created at all — so a button can explain itself
  before it is pressed.
  """
  def configured? do
    case credentials() do
      {key_id, key_secret} when is_binary(key_id) and is_binary(key_secret) -> true
      _missing -> sandbox?()
    end
  end

  @doc """
  Whether simulated links are allowed: on in dev and test, in prod only via `RAZORPAY_SANDBOX`.
  """
  def sandbox? do
    case System.get_env("RAZORPAY_SANDBOX") do
      value when value in ["true", "1"] -> true
      value when value in ["false", "0"] -> false
      _unset -> Application.get_env(:quantum_billing, :razorpay_sandbox, false)
    end
  end

  defp sandbox_payment_link(%Invoice{} = invoice) do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    {:ok,
     %{
       link_id: "plink_sandbox_" <> suffix,
       short_url: "https://rzp.io/i/sandbox-#{invoice.invoice_number}"
     }}
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
