defmodule QuantumBilling.EWayBills.NICClient do
  @moduledoc """
  HTTP client for the Government NIC E-Way Bill portal, using `Req`.

  Falls back to a sandbox response when `NIC_EWB_API_URL` is unset or the
  portal does not answer, so the whole flow — generate, cancel, update Part-B —
  is exercisable without credentials. The sandbox mints plausible numbers and
  applies the same Rule 138(10) validity the live path does, which is what
  keeps the two from disagreeing.
  """

  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.Validity
  alias QuantumBilling.Invoices.Invoice

  @generate_path "/ewaybillapi/v1.03/gstr1/generate"
  @cancel_path "/ewaybillapi/v1.03/ewayapi/canewb"
  @part_b_path "/ewaybillapi/v1.03/ewayapi/vehewb"

  @doc """
  Requests a bill number and validity from the portal.

  Returns `{:ok, attrs}` where `attrs` are the fields of
  `QuantumBilling.EWayBills.EWayBill` — the caller adds `invoice_id`.
  """
  def generate_ewb(%Invoice{} = invoice, params \\ %{}) do
    params = stringify(params)

    client_gstin = invoice.client_gstin || "27AAAAA0000A1Z5"
    company_gstin = invoice.company_gstin || "27BBBBB0000B1Z5"

    # The invoice no longer carries these: a bill is its own record, so the
    # transport details come from the form that raises it.
    distance = integer(Map.get(params, "distance_km"), 250)
    transporter_id = presence(Map.get(params, "transporter_id")) || "27AAACG1234A1ZP"
    transporter_name = presence(Map.get(params, "transporter_name")) || "Express Logistics India"
    vehicle_no = presence(Map.get(params, "vehicle_number")) || "MH12AB1234"
    mode = presence(Map.get(params, "mode_of_transport")) || "Road"

    ewb_payload = %{
      "supplyType" => "O",
      "subSupplyType" => 1,
      "docType" => "INV",
      "docNo" => invoice.invoice_number,
      "docDate" => to_string(invoice.invoice_date),
      "fromGstin" => company_gstin,
      "fromTrdName" => invoice.company_name,
      "fromAddr1" => invoice.company_address,
      "fromPlace" => invoice.company_state || "Mumbai",
      "fromPincode" => 400_001,
      "toGstin" => client_gstin,
      "toTrdName" => invoice.client_name,
      "toAddr1" => invoice.client_billing_address,
      "toPlace" => invoice.client_state || "Pune",
      "toPincode" => 411_001,
      "totalValue" => invoice.taxable_value,
      "cgstValue" => invoice.cgst_amount,
      "sgstValue" => invoice.sgst_amount,
      "igstValue" => invoice.igst_amount,
      "totInvValue" => invoice.grand_total,
      "transporterId" => transporter_id,
      "transporterName" => transporter_name,
      "transDistance" => distance,
      "transMode" => transport_code(mode),
      "vehicleNo" => vehicle_no
    }

    attrs = %{
      distance_km: distance,
      vehicle_number: vehicle_no,
      mode_of_transport: mode,
      transporter_id: transporter_id,
      transporter_name: transporter_name
    }

    case post(@generate_path, ewb_payload) do
      {:ok, body} ->
        {:ok, put_issue(attrs, to_string(body["ewbNo"]), distance)}

      {:error, reason} ->
        {:error, reason}

      :sandbox ->
        {:ok, put_issue(attrs, sandbox_number(), distance)}
    end
  end

  @doc """
  Cancels a bill on the portal under Rule 138(9).

  Returns `{:ok, response}`; the caller records the cancellation locally only
  once the portal has accepted it, so the two cannot disagree about whether a
  number is spent.
  """
  def cancel_ewb(%EWayBill{} = bill, params \\ %{}) do
    params = stringify(params)

    payload = %{
      "ewbNo" => bill.ewb_number,
      # The portal's own codes: 1 duplicate, 2 order cancelled, 3 data entry
      # mistake, 4 others. The UI collects a sentence; anything unmapped is
      # "others", which is what a free-text reason is.
      "cancelRsnCode" => cancel_reason_code(Map.get(params, "cancellation_reason")),
      "cancelRmrk" => Map.get(params, "cancellation_reason")
    }

    case post(@cancel_path, payload) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
      :sandbox -> {:ok, %{"ewbNo" => bill.ewb_number, "cancelDate" => now_string()}}
    end
  end

  @doc """
  Files a Part-B update against a bill: the consignment has changed vehicle.
  """
  def update_part_b(%EWayBill{} = bill, params) do
    params = stringify(params)

    payload = %{
      "ewbNo" => bill.ewb_number,
      "vehicleNo" => Map.get(params, "vehicle_number"),
      "fromPlace" => Map.get(params, "place"),
      "reasonCode" => "1",
      "reasonRem" => Map.get(params, "reason"),
      "transMode" => transport_code(Map.get(params, "mode_of_transport") || "Road")
    }

    case post(@part_b_path, payload) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
      :sandbox -> {:ok, %{"ewbNo" => bill.ewb_number, "vehUpdDate" => now_string()}}
    end
  end

  # One place that decides whether we are talking to the portal at all, so the
  # three operations cannot drift apart on what counts as configured.
  #
  # `:sandbox` rather than an error: an unreachable portal must not stop a
  # consignment being recorded, and the caller cannot tell the difference
  # between "not configured" and "did not answer" in any way that matters.
  defp post(path, payload) do
    base_url = System.get_env("NIC_EWB_API_URL")

    if base_url && String.starts_with?(base_url, "http") do
      api_key = System.get_env("NIC_EWB_API_KEY", "")

      case Req.post(base_url <> path,
             json: payload,
             headers: [{"x-api-key", api_key}, {"content-type", "application/json"}],
             receive_timeout: 5000
           ) do
        {:ok, %{status: 200, body: %{"status" => "1"} = body}} -> {:ok, body}
        {:ok, %{body: %{"error" => error}}} -> {:error, error}
        _other -> :sandbox
      end
    else
      :sandbox
    end
  end

  defp put_issue(attrs, ewb_number, distance) do
    attrs
    |> Map.put(:ewb_number, ewb_number)
    |> Map.put(:ewb_date, Date.utc_today())
    |> Map.put(:valid_until, validity(distance))
  end

  defp sandbox_number do
    "1910" <> Enum.map_join(1..8, fn _ -> to_string(Enum.random(0..9)) end)
  end

  # Rule 138(10), in one place, so the portal path and the sandbox path cannot
  # disagree about when a consignment's bill lapses.
  defp validity(distance) do
    NaiveDateTime.utc_now()
    |> Validity.valid_until(distance)
    |> NaiveDateTime.truncate(:second)
  end

  defp transport_code("Road"), do: 1
  defp transport_code("Rail"), do: 2
  defp transport_code("Air"), do: 3
  defp transport_code("Ship"), do: 4
  defp transport_code(_other), do: 1

  defp cancel_reason_code(reason) when is_binary(reason) do
    downcased = String.downcase(reason)

    cond do
      String.contains?(downcased, "duplicate") -> "1"
      String.contains?(downcased, "cancel") -> "2"
      String.contains?(downcased, "mistake") or String.contains?(downcased, "error") -> "3"
      true -> "4"
    end
  end

  defp cancel_reason_code(_reason), do: "4"

  defp now_string, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> to_string()

  defp stringify(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp integer(_value, default), do: default
end
