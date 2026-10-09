defmodule QuantumBilling.Compliance.GSTNExporter do
  @moduledoc """
  Builds the GSTR-1 JSON the GST Offline Tool accepts, for one return period.

  ## What this used to do

  Three things, all wrong, and the first two in a way nobody could miss once
  they tried it:

    * it read `item.hsn_code`, a field that does not exist, so the download
      raised `KeyError` for any organisation with a single line item — the
      export had never produced a file;
    * it ignored the return period entirely: every invoice ever issued went
      into the file, labelled as that month's return;
    * it reported every line at 18%, whatever rate was actually charged.

  A GSTR-1 is a legal filing. A file with the wrong period, the wrong rates or
  cancelled invoices in it is worse than no file, because it is plausible.

  ## What it does now

  One query for the period, one for its credit notes. Invoices are grouped the
  way the schema expects — B2B by counterparty GSTIN, B2CL for large
  inter-state consumer sales, B2CS summarised by place of supply, rate and
  supply type — and within each invoice the line items are grouped **by their
  own tax rate**, so a bill mixing 5% goods and 18% services reports two rate
  lines. Cancelled invoices are excluded.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  # Above this (whole rupees), an inter-state B2C sale is reported as B2CL, not B2CS.
  @b2cl_threshold 250_000

  @stream_rows 500

  @doc """
  Validates a return period of the form `MMYYYY`.

  Returns `{:ok, period}` or `{:error, message}`. Everything downstream — the
  query, the file name, the header — depends on this, so it is checked once,
  here, rather than trusted from a query string.
  """
  def validate_period(period) when is_binary(period) do
    with <<month::binary-size(2), year::binary-size(4)>> <- String.trim(period),
         {month_number, ""} when month_number in 1..12 <- Integer.parse(month),
         {year_number, ""} when year_number in 2000..2999 <- Integer.parse(year) do
      {:ok, %{period: period, month: month_number, year: year_number}}
    else
      _invalid -> {:error, "A return period looks like MMYYYY, for example 032026."}
    end
  end

  def validate_period(_period), do: {:error, "A return period looks like MMYYYY."}

  @doc """
  The period a return would normally be filed for today: the month just gone.
  """
  def default_period(today \\ Date.utc_today()) do
    previous = today |> Date.beginning_of_month() |> Date.add(-1)

    String.pad_leading(to_string(previous.month), 2, "0") <> to_string(previous.year)
  end

  @doc """
  Builds the GSTR-1 structure for `period` (`"MMYYYY"`).

  Returns `{:ok, map}` or `{:error, message}`.
  """
  def generate_gstr1_json(period) do
    with {:ok, %{period: period, month: month, year: year}} <- validate_period(period) do
      from = Date.new!(year, month, 1)
      to = Date.end_of_month(from)

      organization = Settings.get_organization()
      gstin = presence(organization.gstin) || "URP"

      sections = accumulate(from, to)
      credit_notes = credit_notes_for(from, to)

      {:ok,
       %{
         "gstin" => gstin,
         "fp" => period,
         "version" => "GSTR1_v3.1",
         "hash" => "hash",
         "b2b" => finish_b2b(sections.b2b),
         "b2cl" => finish_b2cl(sections.b2cl),
         "b2cs" => finish_b2cs(sections.b2cs),
         "cdnr" => format_cdnr(credit_notes),
         "hsn" => %{"data" => finish_hsn(sections.hsn)}
       }}
    end
  end

  @doc """
  A short summary of what a period contains, for the page offering the
  download — so an empty month is visible before the file is opened.
  """
  def period_summary(period) do
    with {:ok, %{month: month, year: year}} <- validate_period(period) do
      from = Date.new!(year, month, 1)
      to = Date.end_of_month(from)

      summary =
        Invoice.kept()
        |> in_period(from, to)
        |> select([i], %{
          count: count(i.id),
          value: coalesce(sum(i.grand_total), 0),
          tax:
            coalesce(
              sum(
                coalesce(i.cgst_amount, 0) + coalesce(i.sgst_amount, 0) +
                  coalesce(i.igst_amount, 0) + coalesce(i.cess_amount, 0)
              ),
              0
            )
        })
        |> Repo.one()

      {:ok, summary || %{count: 0, value: 0, tax: 0}}
    end
  end

  # Cancelled invoices are excluded; drafts are included because they hold a number in the series.
  defp in_period(query, from, to) do
    query
    |> where([i], i.invoice_date >= ^from and i.invoice_date <= ^to)
    |> where([i], i.status != "Cancelled")
  end

  # Streamed in one pass to keep memory flat on large periods.
  # Repo.stream/2 cannot preload, so items are fetched per chunk.
  defp accumulate(from, to) do
    empty = %{b2b: %{}, b2cl: %{}, b2cs: %{}, hsn: %{}}

    {:ok, sections} =
      Repo.transaction(
        fn ->
          Invoice.kept()
          |> in_period(from, to)
          |> order_by([i], asc: i.invoice_date, asc: i.id)
          |> Repo.stream(max_rows: @stream_rows)
          |> Stream.chunk_every(@stream_rows)
          |> Enum.reduce(empty, fn invoices, sections ->
            invoices
            |> attach_items()
            |> Enum.reduce(sections, &absorb/2)
          end)
        end,
        timeout: :infinity
      )

    sections
  end

  defp attach_items(invoices) do
    items_by_invoice =
      InvoiceItem
      |> where([i], i.invoice_id in ^Enum.map(invoices, & &1.id))
      |> order_by([i], asc: i.position, asc: i.id)
      |> Repo.all()
      |> Enum.group_by(& &1.invoice_id)

    Enum.map(invoices, fn invoice ->
      %{invoice | items: Map.get(items_by_invoice, invoice.id, [])}
    end)
  end

  # Exactly one of b2b, b2cl and b2cs takes the invoice; its lines always feed the HSN summary.
  defp absorb(%Invoice{} = invoice, sections) do
    sections = %{sections | hsn: absorb_hsn(invoice, sections.hsn)}

    cond do
      registered_buyer?(invoice) ->
        %{sections | b2b: absorb_b2b(invoice, sections.b2b)}

      (invoice.grand_total || 0) > @b2cl_threshold and not Invoice.intra_state?(invoice) ->
        %{sections | b2cl: absorb_b2cl(invoice, sections.b2cl)}

      true ->
        %{sections | b2cs: absorb_b2cs(invoice, sections.b2cs)}
    end
  end

  defp absorb_b2b(invoice, groups) do
    entry =
      %{
        "inum" => invoice.invoice_number,
        "idt" => format_date(invoice.invoice_date),
        "val" => invoice.grand_total,
        "pos" => state_code(invoice.place_of_supply),
        "rchrg" => "N",
        "inv_typ" => "R",
        "irn" => invoice.irn,
        "itms" => rate_lines(invoice)
      }
      |> drop_nils()

    Map.update(groups, invoice.client_gstin, [entry], &[entry | &1])
  end

  defp absorb_b2cl(invoice, groups) do
    entry = %{
      "inum" => invoice.invoice_number,
      "idt" => format_date(invoice.invoice_date),
      "val" => invoice.grand_total,
      "itms" => rate_lines(invoice)
    }

    Map.update(groups, state_code(invoice.place_of_supply), [entry], &[entry | &1])
  end

  # Grouped by place of supply, rate and inter-state flag, as the schema requires.
  defp absorb_b2cs(invoice, groups) do
    intra? = Invoice.intra_state?(invoice)
    pos = state_code(invoice.place_of_supply)

    invoice
    |> rate_totals()
    |> Enum.reduce(groups, fn {rate, totals}, acc ->
      Map.update(
        acc,
        {pos, rate, intra?},
        totals,
        &%{taxable: &1.taxable + totals.taxable, tax: &1.tax + totals.tax}
      )
    end)
  end

  defp absorb_hsn(%Invoice{items: items}, groups) when is_list(items) do
    Enum.reduce(items, groups, fn item, acc ->
      key = {item.hsn_sac || "998311", item.tax_rate || 0}

      line = %{
        taxable: InvoiceItem.amount(item),
        tax: InvoiceItem.tax(item),
        quantity: item.quantity || 0,
        description: item.description,
        uqc: uqc(item)
      }

      Map.update(acc, key, line, fn held ->
        %{
          held
          | taxable: held.taxable + line.taxable,
            tax: held.tax + line.tax,
            quantity: held.quantity + line.quantity
        }
      end)
    end)
  end

  defp absorb_hsn(_invoice, groups), do: groups

  defp credit_notes_for(from, to) do
    from_at = DateTime.new!(from, ~T[00:00:00])
    to_at = DateTime.new!(Date.add(to, 1), ~T[00:00:00])

    CreditNote
    |> where([n], n.inserted_at >= ^from_at and n.inserted_at < ^to_at)
    |> where([n], n.status != "Cancelled")
    # Notes on binned invoices are left out with their invoice.
    |> join(:left, [n], i in assoc(n, :invoice))
    |> where([_n, i], is_nil(i.deleted_at))
    |> order_by([n], asc: n.id)
    |> preload(:invoice)
    |> Repo.all()
  end

  # ── Sections ──────────────────────────────────────────────────────────────

  defp finish_b2b(groups) do
    groups
    |> Enum.map(fn {ctin, entries} -> %{"ctin" => ctin, "inv" => Enum.reverse(entries)} end)
    |> Enum.sort_by(& &1["ctin"])
  end

  defp finish_b2cl(groups) do
    groups
    |> Enum.map(fn {pos, entries} -> %{"pos" => pos, "inv" => Enum.reverse(entries)} end)
    |> Enum.sort_by(& &1["pos"])
  end

  defp finish_b2cs(groups) do
    groups
    |> Enum.map(fn {{pos, rate, intra?}, totals} ->
      {cgst, sgst, igst} = split_tax(totals.tax, intra?)

      %{
        "sply_ty" => if(intra?, do: "INTRA", else: "INTER"),
        "pos" => pos,
        "typ" => "OE",
        "rt" => rate / 1,
        "txval" => totals.taxable,
        "iamt" => igst,
        "camt" => cgst,
        "samt" => sgst,
        "csamt" => 0
      }
    end)
    |> Enum.sort_by(&{&1["pos"], &1["rt"]})
  end

  defp format_cdnr(credit_notes) do
    credit_notes
    |> Enum.filter(&match?(%Invoice{}, &1.invoice))
    |> Enum.group_by(& &1.invoice.client_gstin)
    |> Enum.reject(fn {ctin, _notes} -> ctin in [nil, ""] end)
    |> Enum.map(fn {ctin, notes} ->
      %{
        "ctin" => ctin,
        "nt" =>
          Enum.map(notes, fn note ->
            %{
              "ntty" => if(note.note_type == "Credit", do: "C", else: "D"),
              "nt_num" => note.note_number,
              "nt_dt" => format_date(note.inserted_at),
              "p_gst_flag" => "N",
              "inum" => note.invoice.invoice_number,
              "idt" => format_date(note.invoice.invoice_date),
              "val" => decimal_to_number(note.grand_total),
              "rsn" => note.reason || "Adjustment"
            }
          end)
      }
    end)
    |> Enum.sort_by(& &1["ctin"])
  end

  defp finish_hsn(groups) do
    groups
    |> Enum.sort_by(fn {{hsn, rate}, _totals} -> {hsn, rate} end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{{hsn, rate}, totals}, index} ->
      %{
        "num" => index,
        "hsn_sc" => hsn,
        "desc" => totals.description || "Goods or services",
        "uqc" => totals.uqc,
        "qty" => totals.quantity,
        "rt" => rate / 1,
        "txval" => totals.taxable,
        "val" => totals.taxable + totals.tax,
        "iamt" => 0,
        "camt" => 0,
        "samt" => 0,
        "csamt" => 0
      }
    end)
  end

  # ── Shared shaping ────────────────────────────────────────────────────────

  defp rate_lines(%Invoice{} = invoice) do
    intra? = Invoice.intra_state?(invoice)

    invoice
    |> rate_totals()
    |> Enum.sort_by(fn {rate, _totals} -> rate end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{rate, totals}, index} ->
      {cgst, sgst, igst} = split_tax(totals.tax, intra?)

      %{
        "num" => index,
        "itm_det" => %{
          "rt" => rate / 1,
          "txval" => totals.taxable,
          "iamt" => igst,
          "camt" => cgst,
          "samt" => sgst,
          "csamt" => 0
        }
      }
    end)
  end

  # Falls back to the stored totals when the invoice has no line items.
  defp rate_totals(%Invoice{items: items}) when is_list(items) and items != [] do
    items
    |> Enum.group_by(&(&1.tax_rate || 0))
    |> Map.new(fn {rate, rate_items} ->
      {rate,
       %{
         taxable: Enum.reduce(rate_items, 0, &(InvoiceItem.amount(&1) + &2)),
         tax: Enum.reduce(rate_items, 0, &(InvoiceItem.tax(&1) + &2))
       }}
    end)
  end

  defp rate_totals(%Invoice{} = invoice) do
    taxable = invoice.taxable_value || 0

    tax =
      (invoice.cgst_amount || 0) + (invoice.sgst_amount || 0) + (invoice.igst_amount || 0)

    rate = if taxable > 0, do: round(tax * 100 / taxable), else: 0

    %{rate => %{taxable: taxable, tax: tax}}
  end

  defp split_tax(tax, true) do
    half = div(tax, 2)
    {half, tax - half, 0}
  end

  defp split_tax(tax, false), do: {0, 0, tax}

  defp registered_buyer?(%Invoice{client_gstin: gstin, invoice_type: type}) do
    presence(gstin) != nil and type in [nil, "Tax Invoice", "Export Invoice", "Debit Note"]
  end

  # A bare state name has no code, so it falls back rather than filing "Ma".
  defp state_code(place) when is_binary(place) do
    case Regex.run(~r/\((\d{2})\)|^(\d{2})\b/, place) do
      [_match, code] -> code
      [_match, "", code] -> code
      [_match, code, _] -> code
      _no_code -> "97"
    end
  end

  defp state_code(_place), do: "97"

  defp uqc(%InvoiceItem{unit: unit}) when is_binary(unit) do
    case String.upcase(unit) do
      "NOS" -> "NOS"
      "KG" -> "KGS"
      "LTR" -> "LTR"
      "MTR" -> "MTR"
      "BOX" -> "BOX"
      "SET" -> "SET"
      "PCS" -> "PCS"
      "HRS" -> "OTH"
      _other -> "OTH"
    end
  end

  defp uqc(_item), do: "OTH"

  defp decimal_to_number(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp decimal_to_number(number) when is_number(number), do: number
  defp decimal_to_number(_other), do: 0

  defp drop_nils(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%d-%m-%Y")
  defp format_date(%DateTime{} = datetime), do: format_date(DateTime.to_date(datetime))
  defp format_date(%NaiveDateTime{} = naive), do: format_date(NaiveDateTime.to_date(naive))
  defp format_date(_other), do: format_date(Date.utc_today())

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
