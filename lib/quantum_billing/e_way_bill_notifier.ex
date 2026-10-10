defmodule QuantumBilling.EWayBillNotifier do
  @moduledoc """
  Tells the business when an e-way bill has been raised.

  ## Why this exists

  `organization_settings.notify_ewb_generated` was saved by the notifications
  form and read by nothing: a switch that had never been connected to anything.
  It now gates this.

  ## Who it goes to

  The organisation's own address, not the customer's. An e-way bill is a
  transport document between the consignor, the transporter and the check-post
  — the buyer has no use for it, and mailing it to them would put a number
  they can cancel in their inbox.

  ## Queued, never inline

  Same reasoning as `QuantumBilling.InvoiceNotifier`: generating a bill already
  involves a call to the NIC portal, and a slow relay on top of that would
  stall the click. Failure here must never fail the bill — the bill exists at
  the government's end whatever this module does — so `notify_generated/1`
  always returns `:ok`-ish and logs instead of raising.
  """

  import Swoosh.Email

  require Logger

  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.Mail
  alias QuantumBilling.Settings
  alias QuantumBilling.Workers.EmailWorker

  @doc """
  Queues the "e-way bill generated" notice, if the setting is on.

  Returns `{:ok, delivery}`, `{:ok, :skipped}` when the notification is turned
  off or the organisation has no address on file, or `{:error, reason}`.
  """
  def notify_generated(%EWayBill{} = bill) do
    organization = Settings.get_organization()

    with true <- organization.notify_ewb_generated != false,
         {:ok, recipient} <- recipient(organization) do
      queue(bill, recipient)
    else
      _off_or_unaddressed -> {:ok, :skipped}
    end
  end

  defp queue(%EWayBill{} = bill, recipient) do
    with {:ok, delivery} <-
           Mail.record_queued(%{
             to_email: recipient,
             kind: "e_way_bill",
             subject: subject_for(bill),
             invoice_id: bill.invoice_id
           }),
         {:ok, _job} <-
           %{"delivery_id" => delivery.id, "e_way_bill_id" => bill.id, "kind" => "e_way_bill"}
           |> EmailWorker.new()
           |> Oban.insert() do
      {:ok, delivery}
    else
      {:error, reason} ->
        Logger.warning("[EWayBillNotifier] could not queue notice: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  The finished `Swoosh.Email` for a generated bill.

  Public for the same reason `InvoiceNotifier.build_email/2` is: the worker
  composes and sends in one step.
  """
  def build_email(recipient, %EWayBill{} = bill) do
    organization = Settings.get_organization()
    {from_name, from_email} = Mail.sender(organization, bill.invoice && bill.invoice.company_name)

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject_for(bill))
      |> html_body(html_content(bill, from_name))
      |> text_body(text_content(bill, from_name))

    {:ok, email}
  end

  @doc "The subject line, used by both the ledger and the mail."
  def subject_for(%EWayBill{} = bill) do
    "E-Way Bill #{bill.ewb_number} generated"
  end

  defp recipient(%{email: email}) when is_binary(email) do
    trimmed = String.trim(email)

    if Regex.match?(~r/^[^@,;\s]+@[^@,;\s]+$/, trimmed), do: {:ok, trimmed}, else: :error
  end

  defp recipient(_organization), do: :error

  defp html_content(%EWayBill{} = bill, from_name) do
    """
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e5e7eb; border-radius: 8px;">
      <h2 style="color: #1f2937; margin-top: 0;">E-Way Bill Generated</h2>
      <p style="color: #4b5563; font-size: 15px;">
        Form GST EWB-01 <strong>#{escape(bill.ewb_number)}</strong> has been raised against
        #{escape(document_number(bill))}.
      </p>
      <div style="background-color: #f3f4f6; padding: 16px; border-radius: 6px; margin: 20px 0;">
        <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">EWB Number:</td>
            <td style="padding: 4px 0; font-weight: bold; color: #111827;">#{escape(bill.ewb_number)}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Valid Until:</td>
            <td style="padding: 4px 0; color: #111827;">#{valid_until(bill)}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Vehicle:</td>
            <td style="padding: 4px 0; color: #111827;">#{escape(bill.vehicle_number || "Not recorded")}</td>
          </tr>
          <tr>
            <td style="padding: 4px 0; color: #6b7280;">Distance:</td>
            <td style="padding: 4px 0; color: #111827;">#{bill.distance_km} km</td>
          </tr>
        </table>
      </div>
      <p style="color: #6b7280; font-size: 13px;">
        It can be cancelled within 24 hours of generation, and the vehicle details must be updated
        before the consignment changes vehicles.
      </p>
      <p style="color: #6b7280; font-size: 13px; margin-bottom: 0;">
        <strong>#{escape(from_name)}</strong>
      </p>
    </div>
    """
  end

  defp text_content(%EWayBill{} = bill, from_name) do
    """
    E-Way Bill Generated

    Form GST EWB-01 #{bill.ewb_number} has been raised against #{document_number(bill)}.

    EWB Number:  #{bill.ewb_number}
    Valid Until: #{valid_until(bill)}
    Vehicle:     #{bill.vehicle_number || "Not recorded"}
    Distance:    #{bill.distance_km} km

    It can be cancelled within 24 hours of generation, and the vehicle details
    must be updated before the consignment changes vehicles.

    #{from_name}
    """
  end

  defp document_number(%EWayBill{invoice: %{invoice_number: number}}) when is_binary(number),
    do: number

  defp document_number(%EWayBill{invoice_id: id}), do: "invoice ##{id}"

  defp valid_until(%EWayBill{valid_until: nil}), do: "—"

  defp valid_until(%EWayBill{valid_until: valid_until}),
    do: Calendar.strftime(valid_until, "%d/%m/%Y %H:%M")

  # The consignee name comes from the invoice, so escape it.
  defp escape(nil), do: ""

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
