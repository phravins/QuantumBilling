defmodule QuantumBilling.EWayBills.NICClient do
  @moduledoc """
  HTTP client for the Government NIC E-Way Bill portal, using `Req`.

  Runs in demo mode when `NIC_EWB_API_URL` is unset, so the whole flow —
  generate, cancel, update Part-B — is exercisable without credentials. Demo
  mode mints plausible numbers and applies the same Rule 138(10) validity the
  live path does, and every bill records which mode issued it (`portal_mode`).

  When a portal is configured, a portal that does not answer is an error, never
  a demo number: a failed request must not be recorded as a filed bill. Cancel
  and Part-B follow the bill's own mode, since a demo bill does not exist on
  the portal.
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
      "totalValue" => rupees(invoice.taxable_value),
      "cgstValue" => rupees(invoice.cgst_amount),
      "sgstValue" => rupees(invoice.sgst_amount),
      "igstValue" => rupees(invoice.igst_amount),
      "totInvValue" => rupees(invoice.grand_total),
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

    if live?() do
      with {:ok, body} <- post(@generate_path, ewb_payload) do
        attrs = Map.put(attrs, :portal_mode, "live")
        {:ok, put_issue(attrs, to_string(body["ewbNo"]), distance)}
      end
    else
      attrs = Map.put(attrs, :portal_mode, "demo")
      {:ok, put_issue(attrs, sandbox_number(), distance)}
    end
  end

  @doc """
  A sentence for the user about why the portal did not do what was asked, or
  `nil` when `reason` is not a portal failure. Nothing is recorded in any of
  these cases.
  """
  def error_message(:portal_unavailable),
    do: "The e-way bill portal is not responding. Nothing was filed; try again shortly."

  def error_message(:unexpected_response),
    do: "The e-way bill portal sent an answer this app does not understand. Nothing was filed."

  def error_message(:portal_not_configured),
    do:
      "This bill was filed on the portal, but no portal is configured now (NIC_EWB_API_URL). " <>
        "Nothing was changed."

  def error_message(_reason), do: nil

  @doc """
  True when `NIC_EWB_API_URL` points at a portal. Otherwise bills are minted
  locally and recorded as `"demo"`.
  """
  def live? do
    case System.get_env("NIC_EWB_API_URL") do
      "http" <> _rest -> true
      _other -> false
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
      # Portal codes: 1 duplicate, 2 order cancelled, 3 data entry mistake, 4 others.
      "cancelRsnCode" => cancel_reason_code(Map.get(params, "cancellation_reason")),
      "cancelRmrk" => Map.get(params, "cancellation_reason")
    }

    # A demo bill was never on the portal, so there is nothing there to cancel.
    if EWayBill.demo?(bill) do
      {:ok, %{"ewbNo" => bill.ewb_number, "cancelDate" => now_string()}}
    else
      post(@cancel_path, payload)
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

    if EWayBill.demo?(bill) do
      {:ok, %{"ewbNo" => bill.ewb_number, "vehUpdDate" => now_string()}}
    else
      post(@part_b_path, payload)
    end
  end

  # No fallback to a made-up answer: a portal that does not answer is an error,
  # so a failed request can never be recorded as a filed bill.
  defp post(path, payload) do
    if live?() do
      base_url = System.get_env("NIC_EWB_API_URL")
      api_key = System.get_env("NIC_EWB_API_KEY", "")

      case Req.post(base_url <> path,
             json: payload,
             headers: [{"x-api-key", api_key}, {"content-type", "application/json"}],
             receive_timeout: 5000
           ) do
        {:ok, %{status: 200, body: %{"status" => "1"} = body}} -> {:ok, body}
        {:ok, %{body: %{"error" => error}}} -> {:error, error}
        {:ok, %{status: 200}} -> {:error, :unexpected_response}
        {:ok, _not_200} -> {:error, :portal_unavailable}
        {:error, _exception} -> {:error, :portal_unavailable}
      end
    else
      # A live bill, but the portal is no longer configured.
      {:error, :portal_not_configured}
    end
  end

  # The portal takes rupees as JSON numbers; two decimals survive a float.
  defp rupees(nil), do: 0
  defp rupees(paise) when is_integer(paise), do: paise / 100

  defp put_issue(attrs, ewb_number, distance) do
    attrs
    |> Map.put(:ewb_number, ewb_number)
    |> Map.put(:ewb_date, Date.utc_today())
    |> Map.put(:valid_until, validity(distance))
  end

  defp sandbox_number do
    "1910" <> Enum.map_join(1..8, fn _ -> to_string(Enum.random(0..9)) end)
  end

  # Rule 138(10).
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
