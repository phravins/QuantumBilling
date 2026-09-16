defmodule QuantumBilling.Payments.RazorpayClient do
  @moduledoc """
  Razorpay payment links, and the signature check for their webhooks.

  ## A fake link is worse than no link

  This used to answer every failure — missing credentials, a rejected key, a
  network timeout — by inventing a link: `plink_` plus twelve random digits and
  a `rzp.io/i/qb_INV-1234` URL that does not exist. It was recorded on the
  invoice and put in front of customers, who clicked it and got nothing, while
  the application reported success.

  Simulated links now happen only where they were meant to: in development and
  test, with `:razorpay_sandbox` set. Everywhere else a missing key or a failed
  call is `{:error, reason}` and the page says what went wrong. Sandbox links
  are also labelled as such in the id itself, so a simulated one is
  recognisable wherever it turns up later.

  Credentials come from Settings › Integrations first (encrypted at rest), then
  from the environment.
  """

  require Logger

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings

  @endpoint "https://api.razorpay.com/v1/payment_links"
  @receive_timeout 10_000

  @doc """
  Creates a payment link for an invoice.

  Returns `{:ok, %{link_id:, short_url:}}` or `{:error, message}`.
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
      # Razorpay counts in paise; every amount in this application is whole
      # rupees.
      "amount" => (invoice.grand_total || 0) * 100,
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

  # Razorpay validates the contact details it is given, so a placeholder
  # address would fail the call for an invoice that simply has no email on it.
  defp customer(%Invoice{} = invoice) do
    %{"name" => invoice.client_name}
    |> maybe_put("email", invoice.client_email)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Verifies the HMAC-SHA256 signature of an incoming Razorpay webhook.

  Compared in constant time: a comparison that returns early leaks, through
  timing, how much of a guessed signature was right.
  """
  def verify_webhook_signature(raw_body, signature, secret)
      when is_binary(raw_body) and is_binary(signature) and is_binary(secret) do
    computed =
      :hmac
      |> :crypto.mac(:sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(computed, signature)
  end

  def verify_webhook_signature(_raw_body, _signature, _secret), do: false

  @doc """
  The API credentials, from Settings first and the environment second.

  Settings is checked first because that is where the application asks for
  them, and where they are encrypted at rest; the environment stays supported
  so a deployment can keep them out of the database.
  """
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
  Whether simulated links are allowed.

  On in development and test, off in production unless `RAZORPAY_SANDBOX` says
  otherwise — a demo environment is a legitimate reason to want them.
  """
  def sandbox? do
    case System.get_env("RAZORPAY_SANDBOX") do
      value when value in ["true", "1"] -> true
      value when value in ["false", "0"] -> false
      _unset -> Application.get_env(:quantum_billing, :razorpay_sandbox, false)
    end
  end

  # Marked in the id itself: a link that came from here should be recognisable
  # as simulated in the database, in the audit trail and on the invoice.
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
