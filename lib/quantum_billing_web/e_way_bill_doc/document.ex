defmodule QuantumBillingWeb.EWayBillDoc.Document do
  @moduledoc """
  The official e-way bill — Form GST EWB-01 — as a printable document.

  ## Why the application needed one

  Generating an e-way bill wrote a number onto the invoice and stopped there.
  The list page's View and Print buttons both went to `/invoices?q=<doc no>`,
  a filtered invoice list: the one document a driver is required to carry did
  not exist anywhere in the application. This renders it, in the layout the
  NIC portal prints — the summary band, PART-A, PART-B, the goods table and
  the QR code — so what comes out of the printer is what a checkpost expects.

  ## Self-contained on purpose

  Like the invoice document, this carries its own stylesheet and draws no
  icons from `app.css`: it is printed, saved and reopened away from the
  running application, where a mask-based icon class renders as a blank box.
  Everything the page needs is in the page.
  """
  use QuantumBillingWeb, :html

  alias QuantumBilling.EWayBills.Validity
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.QRCode
  alias QuantumBilling.Settings.Organization

  @doc """
  The e-way bill as a standalone HTML string.

  ## Options

    * `:toolbar` — show the on-screen Print / Download bar (default `true`).
      It carries `class="ewb-screen-only"` and never prints.
    * `:auto_print` — open the browser's print dialog on load (default `false`)
  """
  def html(%Invoice{} = invoice, organization, opts \\ []) do
    assigns = %{
      invoice: invoice,
      org: organization,
      items: items(invoice),
      toolbar: Keyword.get(opts, :toolbar, true),
      auto_print: Keyword.get(opts, :auto_print, false)
    }

    {:safe, iodata} = Phoenix.HTML.html_escape(page(assigns))
    IO.iodata_to_binary(iodata)
  end

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>E-Way Bill {@invoice.ewb_number}</title>
        <style>
          /* Curly interpolation is off inside <style>, so this is plain CSS. */
          @page { size: A4; margin: 10mm; }

          :root {
            --ewb-ink: #18181b;
            --ewb-muted: #52525b;
            --ewb-line: #a1a1aa;
            --ewb-rule: #d4d4d8;
            --ewb-band: #f4f4f5;
          }

          * { box-sizing: border-box; }

          body {
            margin: 0;
            padding: 20px;
            background: #e4e4e7;
            color: var(--ewb-ink);
            font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            font-size: 11px;
            line-height: 1.45;
            -webkit-print-color-adjust: exact;
            print-color-adjust: exact;
          }

          .ewb-screen-only {
            max-width: 780px;
            margin: 0 auto 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
          }

          .ewb-screen-only h1 {
            margin: 0;
            font-size: 14px;
            font-weight: 600;
            letter-spacing: -0.01em;
          }

          .ewb-screen-only p { margin: 2px 0 0; color: var(--ewb-muted); font-size: 11px; }

          .ewb-actions { display: flex; gap: 8px; }

          .ewb-btn {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 7px 13px;
            border: 1px solid var(--ewb-line);
            border-radius: 7px;
            background: #ffffff;
            color: var(--ewb-ink);
            font: inherit;
            font-weight: 500;
            text-decoration: none;
            cursor: pointer;
            transition: background 120ms ease, border-color 120ms ease, transform 80ms ease;
          }

          .ewb-btn:hover { background: var(--ewb-band); border-color: #71717a; }
          .ewb-btn:active { transform: translateY(1px); }

          .ewb-btn--primary {
            background: #18181b;
            border-color: #18181b;
            color: #ffffff;
          }

          .ewb-btn--primary:hover { background: #27272a; border-color: #27272a; }

          .ewb-sheet {
            max-width: 780px;
            margin: 0 auto;
            padding: 16px 18px 18px;
            background: #ffffff;
            border: 1px solid var(--ewb-line);
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
          }

          .ewb-head {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 16px;
            padding-bottom: 10px;
            border-bottom: 2px solid var(--ewb-ink);
          }

          .ewb-title { margin: 0; font-size: 19px; font-weight: 700; letter-spacing: -0.02em; }
          .ewb-form-no { margin: 1px 0 0; font-size: 10px; color: var(--ewb-muted); letter-spacing: 0.06em; text-transform: uppercase; }
          .ewb-issuer { margin: 6px 0 0; font-size: 11px; font-weight: 600; }
          .ewb-issuer span { display: block; font-weight: 400; color: var(--ewb-muted); }

          .ewb-qr {
            width: 104px;
            flex: none;
            text-align: center;
          }

          .ewb-qr svg { width: 104px; height: 104px; display: block; }
          .ewb-qr figcaption { margin-top: 3px; font-size: 8.5px; color: var(--ewb-muted); letter-spacing: 0.04em; }

          .ewb-band {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            border: 1px solid var(--ewb-rule);
            border-bottom: none;
            margin-top: 12px;
          }

          .ewb-band > div {
            padding: 6px 9px;
            border-bottom: 1px solid var(--ewb-rule);
            border-right: 1px solid var(--ewb-rule);
          }

          .ewb-band > div:nth-child(4n) { border-right: none; }

          .ewb-band dt {
            margin: 0;
            font-size: 8.5px;
            letter-spacing: 0.06em;
            text-transform: uppercase;
            color: var(--ewb-muted);
          }

          .ewb-band dd { margin: 1px 0 0; font-size: 11.5px; font-weight: 600; }
          .ewb-band dd.is-wide { letter-spacing: 0.04em; }

          .ewb-part { margin-top: 14px; }

          .ewb-part > h2 {
            margin: 0 0 0;
            padding: 4px 9px;
            background: var(--ewb-ink);
            color: #ffffff;
            font-size: 10px;
            font-weight: 700;
            letter-spacing: 0.14em;
            text-transform: uppercase;
          }

          table { width: 100%; border-collapse: collapse; }

          .ewb-rows td {
            padding: 5px 9px;
            border: 1px solid var(--ewb-rule);
            vertical-align: top;
          }

          .ewb-rows td.ewb-key {
            width: 31%;
            background: var(--ewb-band);
            font-weight: 500;
            color: var(--ewb-muted);
          }

          .ewb-rows td.ewb-key b { color: var(--ewb-ink); font-weight: 600; }
          .ewb-rows strong { font-weight: 600; }
          .ewb-rows small { display: block; color: var(--ewb-muted); font-size: 10px; }

          .ewb-grid th {
            padding: 5px 9px;
            border: 1px solid var(--ewb-rule);
            background: var(--ewb-band);
            font-size: 8.5px;
            font-weight: 600;
            letter-spacing: 0.05em;
            text-transform: uppercase;
            color: var(--ewb-muted);
            text-align: left;
          }

          .ewb-grid td {
            padding: 5px 9px;
            border: 1px solid var(--ewb-rule);
            vertical-align: top;
          }

          .ewb-num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
          .ewb-grid tfoot td { background: var(--ewb-band); font-weight: 600; }
          .ewb-grid tbody td small { display: block; color: var(--ewb-muted); font-size: 10px; }

          .ewb-totals { margin-top: 10px; display: flex; justify-content: flex-end; }

          .ewb-totals table { width: 300px; }
          .ewb-totals td { padding: 4px 9px; border: 1px solid var(--ewb-rule); }
          .ewb-totals td:last-child { text-align: right; font-variant-numeric: tabular-nums; }
          .ewb-totals tr.is-total td { background: var(--ewb-ink); color: #ffffff; font-weight: 700; border-color: var(--ewb-ink); }

          .ewb-foot {
            margin-top: 14px;
            display: flex;
            align-items: flex-end;
            justify-content: space-between;
            gap: 20px;
            padding-top: 10px;
            border-top: 1px solid var(--ewb-rule);
          }

          .ewb-note { margin: 0; max-width: 62%; font-size: 9.5px; color: var(--ewb-muted); }
          .ewb-note b { color: var(--ewb-ink); }

          .ewb-sign { text-align: center; font-size: 9.5px; color: var(--ewb-muted); }
          .ewb-sign span { display: block; width: 190px; margin-bottom: 3px; padding-top: 26px; border-bottom: 1px solid var(--ewb-line); }

          @media print {
            body { padding: 0; background: #ffffff; }
            .ewb-screen-only { display: none !important; }
            .ewb-sheet { max-width: none; border: none; box-shadow: none; padding: 0; }
          }
        </style>
      </head>

      <body>
        <div :if={@toolbar} class="ewb-screen-only">
          <div>
            <h1>E-Way Bill {grouped(@invoice.ewb_number)}</h1>
            <p>Form GST EWB-01 &middot; {status_line(@invoice)}</p>
          </div>

          <div class="ewb-actions">
            <a class="ewb-btn" href={~p"/e-way-bills"}>Back to e-way bills</a>
            <a class="ewb-btn" href={~p"/e-way-bills/#{@invoice.id}/print/download"}>Download PDF</a>
            <%!-- A raw handler rather than a colocated hook: this document is
            rendered by a controller, outside the LiveSocket, so there is no
            hook to colocate onto. --%>
            <button type="button" class="ewb-btn ewb-btn--primary" onclick="window.print()">
              Print
            </button>
          </div>
        </div>

        <main class="ewb-sheet">
          <header class="ewb-head">
            <div>
              <h1 class="ewb-title">e-Way Bill</h1>
              <p class="ewb-form-no">Form GST EWB-01</p>
              <p class="ewb-issuer">
                {blank(@invoice.company_name)} <span>{blank(@invoice.company_gstin)}</span>
              </p>
            </div>

            <figure class="ewb-qr">
              {raw(qr_svg(@invoice))}
              <figcaption>Scan to verify</figcaption>
            </figure>
          </header>

          <dl class="ewb-band">
            <div>
              <dt>E-Way Bill No.</dt>
              <dd class="is-wide">{grouped(@invoice.ewb_number)}</dd>
            </div>

            <div>
              <dt>Generated On</dt>
              <dd>{on_date(@invoice.ewb_date)}</dd>
            </div>

            <div>
              <dt>Valid From</dt>
              <dd>{on_date(@invoice.ewb_date)}</dd>
            </div>

            <div>
              <dt>Valid Until</dt>
              <dd>{on_datetime(@invoice.ewb_valid_until)}</dd>
            </div>

            <div>
              <dt>Generated By</dt>
              <dd>{blank(@invoice.company_gstin)}</dd>
            </div>

            <div>
              <dt>Mode</dt>
              <dd>{blank(@invoice.mode_of_transport)}</dd>
            </div>

            <div>
              <dt>Approx. Distance</dt>
              <dd>{distance(@invoice)}</dd>
            </div>

            <div>
              <dt>Validity Period</dt>
              <dd>{validity_days(@invoice)}</dd>
            </div>
          </dl>

          <section class="ewb-part">
            <h2>Part - A</h2>

            <table class="ewb-rows">
              <tbody>
                <tr>
                  <td class="ewb-key"><b>A.1</b> GSTIN of Supplier</td>
                  <td>
                    <strong>{blank(@invoice.company_gstin)}</strong>
                    <small>{blank(@invoice.company_name)}</small>
                  </td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.2</b> Place of Dispatch</td>
                  <td>{dispatch_place(@invoice, @org)}</td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.3</b> GSTIN of Recipient</td>
                  <td>
                    <strong>{recipient_gstin(@invoice)}</strong>
                    <small>{blank(@invoice.client_name)}</small>
                  </td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.4</b> Place of Delivery</td>
                  <td>{delivery_place(@invoice)}</td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.5</b> Document Number</td>
                  <td>
                    <strong>{blank(@invoice.invoice_number)}</strong>
                    <small>{blank(@invoice.invoice_type)}</small>
                  </td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.6</b> Document Date</td>
                  <td>{on_date(@invoice.invoice_date)}</td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.7</b> Value of Goods</td>
                  <td>
                    <strong>{rupees(@invoice.grand_total || 0, decimals: 2, space: true)}</strong>
                  </td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.8</b> HSN Code</td>
                  <td>{hsn_codes(@items)}</td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.9</b> Reason for Transportation</td>
                  <td>{transport_reason(@invoice)}</td>
                </tr>

                <tr>
                  <td class="ewb-key"><b>A.10</b> Transporter</td>
                  <td>
                    <strong>{blank(@invoice.transporter_name)}</strong>
                    <small>{blank(@invoice.transporter_id)}</small>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>

          <section class="ewb-part">
            <h2>Part - B</h2>

            <table class="ewb-grid">
              <thead>
                <tr>
                  <th>Mode</th>
                  <th>Vehicle / Trans Doc No.</th>
                  <th>From</th>
                  <th>Entered Date</th>
                  <th>Entered By</th>
                </tr>
              </thead>

              <tbody>
                <tr>
                  <td>{blank(@invoice.mode_of_transport)}</td>
                  <td><strong>{blank(@invoice.vehicle_number)}</strong></td>
                  <td>{from_place(@invoice, @org)}</td>
                  <td>{on_date(@invoice.ewb_date)}</td>
                  <td>{blank(@invoice.company_gstin)}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <section class="ewb-part">
            <h2>Goods Details</h2>

            <table class="ewb-grid">
              <thead>
                <tr>
                  <th style="width: 12%">HSN</th>
                  <th>Product Name &amp; Description</th>
                  <th style="width: 12%">Quantity</th>
                  <th style="width: 17%" class="ewb-num">Taxable Value</th>
                  <th style="width: 20%" class="ewb-num">Tax Rate (C+S+I+Cess)</th>
                </tr>
              </thead>

              <tbody>
                <tr :for={item <- @items}>
                  <td>{blank(item.hsn_sac)}</td>
                  <td>{blank(item.description)}</td>
                  <td>{item.quantity || 0} {item.unit || "Nos"}</td>
                  <td class="ewb-num">{rupees(item.amount || 0, decimals: 2, space: true)}</td>
                  <td class="ewb-num">{tax_split(@invoice, item)}</td>
                </tr>

                <tr :if={@items == []}>
                  <td colspan="5">No line items recorded on this document.</td>
                </tr>
              </tbody>

              <tfoot>
                <tr>
                  <td colspan="2">Total</td>
                  <td>{@invoice.total_quantity || 0}</td>
                  <td class="ewb-num">
                    {rupees(@invoice.taxable_value || 0, decimals: 2, space: true)}
                  </td>
                  <td></td>
                </tr>
              </tfoot>
            </table>
          </section>

          <div class="ewb-totals">
            <table>
              <tbody>
                <tr>
                  <td>Taxable Value</td>
                  <td>{rupees(@invoice.taxable_value || 0, decimals: 2, space: true)}</td>
                </tr>

                <tr :if={(@invoice.cgst_amount || 0) > 0}>
                  <td>CGST</td>
                  <td>{rupees(@invoice.cgst_amount, decimals: 2, space: true)}</td>
                </tr>

                <tr :if={(@invoice.sgst_amount || 0) > 0}>
                  <td>SGST</td>
                  <td>{rupees(@invoice.sgst_amount, decimals: 2, space: true)}</td>
                </tr>

                <tr :if={(@invoice.igst_amount || 0) > 0}>
                  <td>IGST</td>
                  <td>{rupees(@invoice.igst_amount, decimals: 2, space: true)}</td>
                </tr>

                <tr :if={(@invoice.cess_amount || 0) > 0}>
                  <td>Cess</td>
                  <td>{rupees(@invoice.cess_amount, decimals: 2, space: true)}</td>
                </tr>

                <tr class="is-total">
                  <td>Total Invoice Value</td>
                  <td>{rupees(@invoice.grand_total || 0, decimals: 2, space: true)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <footer class="ewb-foot">
            <p class="ewb-note">
              <b>Validity:</b> one day for every 200 km of the approximate distance, or part
              thereof, expiring at midnight of the last day — Rule 138(10) of the CGST Rules.
              Part-B has to be updated before the vehicle changes. This document must travel
              with the consignment and be produced on demand.
            </p>

            <div class="ewb-sign">
              <span></span> Signature of the person in charge
            </div>
          </footer>
        </main>
        <script :if={@auto_print}>
          // Straight into the print dialog, where "Save as PDF" writes the file.
          window.addEventListener("load", () => window.print())
        </script>
      </body>
    </html>
    """
  end

  @doc """
  What the e-way bill's QR encodes.

  The portal's printed QR carries the bill number, the GSTIN that generated it
  and the generation date, separated by slashes — enough for an officer's app
  to look the consignment up. Exposed so the document test can read it back
  without parsing an SVG.
  """
  def qr_payload(%Invoice{} = invoice) do
    date =
      case invoice.ewb_date do
        %Date{} = date -> Calendar.strftime(date, "%d/%m/%Y")
        _missing -> ""
      end

    Enum.join([invoice.ewb_number || "", invoice.company_gstin || "", date], "/")
  end

  defp qr_svg(%Invoice{ewb_number: number} = invoice) when is_binary(number) and number != "" do
    QRCode.generate_svg(qr_payload(invoice), width: 104)
  end

  defp qr_svg(_no_bill_yet), do: ""

  # An e-way bill printed off an invoice whose items were never loaded would
  # otherwise raise on the goods table — the one table an officer reads.
  defp items(%Invoice{items: items}) when is_list(items), do: items
  defp items(_not_loaded), do: []

  @doc """
  A 12-digit e-way bill number in the groups of four the portal prints.
  """
  def grouped(number) when is_binary(number) and number != "" do
    number
    |> String.replace(~r/\s/, "")
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  def grouped(_missing), do: "—"

  defp status_line(%Invoice{} = invoice) do
    "Document " <>
      blank(invoice.invoice_number) <>
      " · valid until " <>
      on_datetime(invoice.ewb_valid_until)
  end

  defp on_date(%Date{} = date), do: Calendar.strftime(date, "%d/%m/%Y")
  defp on_date(_missing), do: "—"

  defp on_datetime(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%d/%m/%Y %I:%M %p")
  defp on_datetime(_missing), do: "—"

  defp distance(%Invoice{distance_km: km}) when is_integer(km) and km > 0, do: "#{km} km"
  defp distance(_unknown), do: "—"

  defp validity_days(%Invoice{distance_km: km}) do
    case Validity.days(km) do
      1 -> "1 day"
      days -> "#{days} days"
    end
  end

  # An unregistered recipient is not a blank on an e-way bill, it is "URP" —
  # the portal's own marker, and what an officer expects to read.
  defp recipient_gstin(%Invoice{client_gstin: gstin}) when is_binary(gstin) and gstin != "",
    do: gstin

  defp recipient_gstin(_unregistered), do: "URP"

  defp dispatch_place(%Invoice{} = invoice, org) do
    [org_field(org, :city), invoice.company_state || org_field(org, :state)]
    |> place_line()
    |> with_pin(org_field(org, :pincode))
    |> Kernel.||(blank(invoice.company_address))
  end

  defp delivery_place(%Invoice{} = invoice) do
    [invoice.client_city, invoice.client_state || invoice.place_of_supply]
    |> place_line()
    |> with_pin(invoice.client_pincode)
    |> Kernel.||(blank(invoice.client_billing_address))
  end

  defp from_place(%Invoice{} = invoice, org) do
    presence(org_field(org, :city)) || presence(invoice.company_state) || "—"
  end

  defp org_field(%Organization{} = org, field), do: Map.get(org, field)
  defp org_field(_no_org, _field), do: nil

  defp with_pin(nil, _pincode), do: nil

  defp with_pin(line, pincode) do
    case presence(pincode) do
      nil -> line
      pin -> line <> " - " <> pin
    end
  end

  defp place_line(parts) do
    case parts |> Enum.map(&presence/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  defp hsn_codes([]), do: "—"

  defp hsn_codes(items) do
    items
    |> Enum.map(& &1.hsn_sac)
    |> Enum.map(&presence/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> "—"
      codes -> Enum.join(codes, ", ")
    end
  end

  defp transport_reason(%Invoice{export_type: type}) when is_binary(type) and type != "DOMESTIC",
    do: "Export"

  defp transport_reason(_domestic), do: "Supply"

  # The rate an officer reads off the goods table is the split, not the total:
  # an inter-state consignment carries all of it as IGST, an intra-state one
  # halves it between the centre and the state.
  defp tax_split(%Invoice{igst_amount: igst}, item) when is_integer(igst) and igst > 0 do
    rate = item.tax_rate || 0
    "0.00 + 0.00 + #{decimal(rate)} + 0.00"
  end

  defp tax_split(_intra_state, item) do
    half = (item.tax_rate || 0) / 2
    "#{decimal(half)} + #{decimal(half)} + 0.00 + 0.00"
  end

  defp decimal(number), do: :erlang.float_to_binary(number / 1, decimals: 2)

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(value), do: to_string(value)

  defp blank(value), do: presence(value) || "—"
end
