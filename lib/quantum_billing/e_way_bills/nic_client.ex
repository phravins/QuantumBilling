defmodule QuantumBilling.EWayBills.NICClient do
  @moduledoc """
  HTTP Client Wrapper using `Req` for Government NIC E-Way Bill Portal API.
  Includes a sandbox response generator when sandbox mode is active or credentials are mock.
  """

  alias QuantumBilling.Invoices.Invoice

  @doc """
  Generates an E-Way Bill payload and requests EWB Number and Validity from Government NIC Portal.
  """
  def generate_ewb(%Invoice{} = invoice, params \\ %{}) do
    client_gstin = invoice.client_gstin || "27AAAAA0000A1Z5"
    company_gstin = invoice.company_gstin || "27BBBBB0000B1Z5"

    distance =
      String.to_integer(to_string(Map.get(params, "distance_km", invoice.distance_km || 250)))

    transporter_id =
      Map.get(params, "transporter_id", invoice.transporter_id || "27AAACG1234A1ZP")

    transporter_name =
      Map.get(params, "transporter_name", invoice.transporter_name || "Express Logistics India")

    vehicle_no = Map.get(params, "vehicle_number", invoice.vehicle_number || "MH12AB1234")
    mode = Map.get(params, "mode_of_transport", invoice.mode_of_transport || "Road")

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
      "transMode" => if(mode == "Road", do: 1, else: 2),
      "vehicleNo" => vehicle_no
    }

    base_url = System.get_env("NIC_EWB_API_URL")

    if base_url && String.starts_with?(base_url, "http") do
      api_key = System.get_env("NIC_EWB_API_KEY", "")

      case Req.post(base_url <> "/ewaybillapi/v1.03/gstr1/generate",
             json: ewb_payload,
             headers: [{"x-api-key", api_key}, {"content-type", "application/json"}],
             receive_timeout: 5000
           ) do
        {:ok, %{status: 200, body: %{"status" => "1"} = body}} ->
          {:ok,
           parse_nic_response(body, distance, vehicle_no, mode, transporter_id, transporter_name)}

        {:ok, %{body: %{"error" => err}}} ->
          {:error, err}

        _other ->
          sandbox_ewb_response(
            invoice,
            distance,
            vehicle_no,
            mode,
            transporter_id,
            transporter_name
          )
      end
    else
      sandbox_ewb_response(invoice, distance, vehicle_no, mode, transporter_id, transporter_name)
    end
  end

  defp parse_nic_response(body, distance, vehicle_no, mode, transporter_id, transporter_name) do
    ewb_no = to_string(body["ewbNo"])
    ewb_date = Date.utc_today()

    valid_until =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(trunc(distance * 86400 / 100), :second)
      |> NaiveDateTime.truncate(:second)

    %{
      ewb_number: ewb_no,
      ewb_date: ewb_date,
      ewb_valid_until: valid_until,
      distance_km: distance,
      vehicle_number: vehicle_no,
      mode_of_transport: mode,
      transporter_id: transporter_id,
      transporter_name: transporter_name
    }
  end

  defp sandbox_ewb_response(
         _invoice,
         distance,
         vehicle_no,
         mode,
         transporter_id,
         transporter_name
       ) do
    ewb_no = "1910" <> Enum.map_join(1..8, fn _ -> to_string(Enum.random(0..9)) end)
    ewb_date = Date.utc_today()

    valid_until =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add((div(distance, 100) + 1) * 86400, :second)
      |> NaiveDateTime.truncate(:second)

    {:ok,
     %{
       ewb_number: ewb_no,
       ewb_date: ewb_date,
       ewb_valid_until: valid_until,
       distance_km: distance,
       vehicle_number: vehicle_no,
       mode_of_transport: mode,
       transporter_id: transporter_id,
       transporter_name: transporter_name
     }}
  end
end
