defmodule QuantumBilling.EInvoice.IRPClient do
  @moduledoc """
  HTTP Client for Government Invoice Registration Portal (IRP) / NIC E-Invoice API.

  Handles authentication token retrieval, IRN (Invoice Reference Number) generation,
  cancellation, and QR code payload parsing using the preferred `:req` (`Req`) HTTP library.

  When production API credentials (`IRP_CLIENT_ID`, `IRP_CLIENT_SECRET`) are absent or
  when running in sandbox mode (`IRP_SANDBOX=true`), it generates realistic NIC-compliant
  mock responses with SHA-256 IRNs and Signed QR payloads for seamless local testing.
  """

  alias QuantumBilling.EInvoice
  alias QuantumBilling.Invoices.Invoice

  @default_endpoint "https://einv-apisandbox.nic.in"

  @doc """
  Generates an IRN for the given invoice by posting to the IRP API or sandbox emulator.
  """
  def generate_irn(%Invoice{} = invoice, opts \\ []) do
    if sandbox_mode?() or Keyword.get(opts, :force_sandbox, false) do
      simulate_irp_response(invoice)
    else
      do_live_generate_irn(invoice)
    end
  end

  defp do_live_generate_irn(%Invoice{} = invoice) do
    endpoint = System.get_env("IRP_API_URL", @default_endpoint)
    client_id = System.get_env("IRP_CLIENT_ID")
    client_secret = System.get_env("IRP_CLIENT_SECRET")
    user_gstin = invoice.company_gstin || System.get_env("IRP_GSTIN", "27AABCU9603R1ZM")

    json_payload = EInvoice.to_json(invoice)

    req =
      Req.new(
        base_url: endpoint,
        headers: [
          {"content-type", "application/json"},
          {"client-id", client_id},
          {"client-secret", client_secret},
          {"gstin", user_gstin}
        ]
      )

    case Req.post(req, url: "/einv/api/invoice/generate", json: json_payload) do
      {:ok, %{status: 200, body: %{"status" => "1", "data" => data}}} ->
        {:ok,
         %{
           irn: data["Irn"],
           ack_no: to_string(data["AckNo"]),
           ack_date: parse_ack_date(data["AckDt"]),
           signed_qr_code: data["SignedQRCode"],
           signed_invoice: data["SignedInvoice"]
         }}

      {:ok, %{status: 200, body: %{"error" => errors}}} ->
        {:error, format_errors(errors)}

      {:ok, %{status: status, body: body}} ->
        {:error, "IRP API returned HTTP #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, "HTTP connection error: #{Exception.message(exception)}"}
    end
  end

  defp simulate_irp_response(%Invoice{} = invoice) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Generate a deterministic 64-char hex IRN based on invoice number and company gstin
    raw_key = "#{invoice.company_gstin}:#{invoice.invoice_number}:#{invoice.grand_total}"
    irn = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
    ack_no = "1" <> to_string(:erlang.phash2(raw_key, 900_000_000) + 100_000_000)

    # Signed QR payload structure per NIC specification
    qr_data =
      Jason.encode!(%{
        "SellerGstin" => invoice.company_gstin,
        "BuyerGstin" => invoice.client_gstin,
        "DocNo" => invoice.invoice_number,
        "DocTyp" => "INV",
        "DocDt" => to_string(invoice.invoice_date),
        "TotVal" => invoice.grand_total,
        "ItemCnt" => invoice.total_items,
        "MainHsnCode" => hd(invoice.items || [%{hsn_sac: "998314"}]).hsn_sac,
        "Irn" => irn,
        "AckNo" => ack_no,
        "AckDt" => DateTime.to_iso8601(now)
      })

    {:ok,
     %{
       irn: irn,
       ack_no: ack_no,
       ack_date: now,
       signed_qr_code: qr_data,
       signed_invoice: "MOCK_SIGNED_JWT_#{irn}"
     }}
  end

  defp sandbox_mode? do
    client_id = System.get_env("IRP_CLIENT_ID")
    client_secret = System.get_env("IRP_CLIENT_SECRET")
    force_sandbox = System.get_env("IRP_SANDBOX", "true") in ["true", "1"]

    force_sandbox or is_nil(client_id) or is_nil(client_secret)
  end

  defp parse_ack_date(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_ack_date(date_str) when is_binary(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp format_errors(errors) when is_list(errors) do
    Enum.map_join(errors, ", ", fn
      %{"errorMessage" => msg} -> msg
      other -> inspect(other)
    end)
  end

  defp format_errors(errors), do: inspect(errors)
end
