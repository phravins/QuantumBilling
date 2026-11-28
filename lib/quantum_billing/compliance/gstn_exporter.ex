defmodule QuantumBilling.Compliance.GSTNExporter do
  @moduledoc """
  Builds the GSTR-1 JSON the GST Offline Tool accepts, for one return period.

  Tables filled:

    * 4 (`b2b`): registered buyers, by GSTIN.
    * 5 (`b2cl`): inter-state consumer invoices above the B2CL limit, by place
      of supply. The limit is ₹1,00,000 from August 2024 and ₹2,50,000 before.
    * 7 (`b2cs`): every other consumer sale, by place of supply, rate and
      supply type, net of the notes raised against those sales.
    * 9B (`cdnr`, `cdnur`): notes against Table 4 and Table 5 invoices.
    * 12 (`hsn`): by HSN/SAC and rate, split into `hsn_b2b` and `hsn_b2c`, with
      the tax heads, net of notes.
    * 13 (`doc_issue`): the number ranges used, with cancelled ones counted.

  Every table is built from the same per-line amounts (`lines/1`), so Table 12
  adds up to Tables 4, 5, 7 and 9B. A GST note stores only its totals, so its
  lines are its invoice's, scaled to them.

  Cancelled and binned invoices are left out of the supplies, but still count
  in Table 13 because they used a number.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Money
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  # Notification 12/2024-CT: from 1 August 2024 an inter-state consumer invoice
  # above ₹1,00,000 is B2CL; before, the limit was ₹2,50,000. Held in paise.
  @b2cl_limit_from ~D[2024-08-01]
  @b2cl_threshold 10_000_000
  @b2cl_threshold_before 25_000_000

  @fallback_hsn "998311"
  @amounts [:taxable, :cgst, :sgst, :igst]
  @stream_rows 500

  @doc "Validates a `MMYYYY` return period: `{:ok, period}` or `{:error, message}`."
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

  defp gst_business do
    case QuantumBilling.Tax.ensure_gst() do
      :ok -> :ok
      {:error, :gst_only} -> {:error, QuantumBilling.Tax.gst_only_message(:gstr1)}
    end
  end

  @doc """
  The period a return would normally be filed for today: the month just gone.
  """
  def default_period(today \\ Date.utc_today()) do
    previous = today |> Date.beginning_of_month() |> Date.add(-1)

    String.pad_leading(to_string(previous.month), 2, "0") <> to_string(previous.year)
  end

  @doc """
  Builds the GSTR-1 structure for `period` (`"MMYYYY"`): `{:ok, map}` or `{:error, message}`.
  A VAT business files no GSTR-1, so it gets the reason instead.
  """
  def generate_gstr1_json(period) do
    with :ok <- gst_business(),
         {:ok, %{period: period, month: month, year: year}} <- validate_period(period) do
      from = Date.new!(year, month, 1)
      to = Date.end_of_month(from)

      organization = Settings.get_organization()
      gstin = presence(organization.gstin) || "URP"

      # B2CS and HSN are net of the notes, so the notes go in before either is finished.
      sections =
        from
        |> credit_notes_for(to)
        |> Enum.reduce(accumulate(from, to), &absorb_note/2)

      {:ok,
       %{
         "gstin" => gstin,
         "fp" => period,
         "version" => "GSTR1_v3.1",
         "hash" => "hash",
         "b2b" => finish_by(sections.b2b, "ctin"),
         "b2cl" => finish_by(sections.b2cl, "pos"),
         "b2cs" => finish_b2cs(sections.b2cs),
         "cdnr" => finish_by(sections.cdnr, "ctin", "nt"),
         "cdnur" => Enum.reverse(sections.cdnur),
         "hsn" => finish_hsn(sections.hsn),
         "doc_issue" => doc_issue(from, to)
       }}
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
    empty = %{b2b: %{}, b2cl: %{}, b2cs: %{}, cdnr: %{}, cdnur: [], hsn: %{}}

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

  # ── Classification ────────────────────────────────────────────────────────

  # Which of Tables 4, 5 and 7 the invoice belongs to. A note follows its invoice.
  defp section(%Invoice{} = invoice) do
    cond do
      registered_buyer?(invoice) ->
        :b2b

      (invoice.grand_total || 0) > b2cl_threshold(invoice.invoice_date) and
          not Invoice.intra_state?(invoice) ->
        :b2cl

      true ->
        :b2cs
    end
  end

  # By the invoice's own date, so a note on an older invoice lands where that
  # invoice was filed, and an older period regenerates as it was filed.
  defp b2cl_threshold(%Date{} = date) do
    if Date.compare(date, @b2cl_limit_from) == :lt,
      do: @b2cl_threshold_before,
      else: @b2cl_threshold
  end

  defp b2cl_threshold(_date), do: @b2cl_threshold

  # ── Invoices ──────────────────────────────────────────────────────────────

  # Exactly one of b2b, b2cl and b2cs takes the invoice; its lines always feed the HSN summary.
  defp absorb(%Invoice{} = invoice, sections) do
    lines = lines(invoice)
    section = section(invoice)
    sections = %{sections | hsn: absorb_hsn(lines, section == :b2b, sections.hsn, 1)}

    case section do
      :b2b -> %{sections | b2b: absorb_b2b(invoice, lines, sections.b2b)}
      :b2cl -> %{sections | b2cl: absorb_b2cl(invoice, lines, sections.b2cl)}
      :b2cs -> %{sections | b2cs: absorb_b2cs(invoice, lines, sections.b2cs, 1)}
    end
  end

  defp absorb_b2b(invoice, lines, groups) do
    entry =
      %{
        "inum" => invoice.invoice_number,
        "idt" => format_date(invoice.invoice_date),
        "val" => rupees(invoice.grand_total),
        "pos" => state_code(invoice.place_of_supply),
        "rchrg" => reverse_charge(invoice),
        "inv_typ" => "R",
        # A demo IRN was never registered; filing it would report a number the
        # government has no record of.
        "irn" => if(Invoice.demo_irn?(invoice), do: nil, else: invoice.irn),
        "itms" => rate_lines(lines, :all_heads)
      }
      |> drop_nils()

    Map.update(groups, invoice.client_gstin, [entry], &[entry | &1])
  end

  defp absorb_b2cl(invoice, lines, groups) do
    entry = %{
      "inum" => invoice.invoice_number,
      "idt" => format_date(invoice.invoice_date),
      "val" => rupees(invoice.grand_total),
      "itms" => rate_lines(lines, :igst_only)
    }

    Map.update(groups, state_code(invoice.place_of_supply), [entry], &[entry | &1])
  end

  # Grouped by place of supply, rate and inter-state flag, as the schema requires.
  # `sign` is -1 for a credit note, which takes its amounts back off.
  defp absorb_b2cs(invoice, lines, groups, sign) do
    intra? = Invoice.intra_state?(invoice)
    pos = state_code(invoice.place_of_supply)

    Enum.reduce(lines, groups, fn line, acc ->
      Map.update(acc, {pos, line.rate, intra?}, add(%{}, line, sign), &add(&1, line, sign))
    end)
  end

  defp absorb_hsn(lines, b2b?, groups, sign) do
    Enum.reduce(lines, groups, fn line, acc ->
      key = {b2b?, line.hsn, line.rate}
      qty = if sign < 0, do: Decimal.negate(line.qty), else: line.qty

      start = %{desc: line.desc, uqc: line.uqc, qty: Decimal.new(0)}

      Map.update(acc, key, add_hsn(start, line, sign, qty), &add_hsn(&1, line, sign, qty))
    end)
  end

  defp add_hsn(held, line, sign, qty) do
    held
    |> add(line, sign)
    |> Map.update!(:qty, &Decimal.add(&1, qty))
  end

  # ── Notes (Table 9B, and netted into Tables 7 and 12) ──────────────────────

  # By the note's own date in the business's timezone, not its UTC save time.
  defp credit_notes_for(from, to) do
    notes =
      CreditNote
      |> where([n], n.note_date >= ^from and n.note_date <= ^to)
      |> where([n], n.status != "Cancelled")
      # Notes on binned invoices are left out with their invoice.
      |> join(:inner, [n], i in assoc(n, :invoice))
      |> where([_n, i], is_nil(i.deleted_at))
      |> order_by([n], asc: n.note_date, asc: n.id)
      |> preload(:invoice)
      |> Repo.all()

    invoices =
      notes
      |> Enum.map(& &1.invoice)
      |> Enum.uniq_by(& &1.id)
      |> attach_items()
      |> Map.new(&{&1.id, &1})

    Enum.map(notes, &%{&1 | invoice: Map.fetch!(invoices, &1.invoice_id)})
  end

  defp absorb_note(%CreditNote{invoice: invoice} = note, sections) do
    lines = note_lines(note)
    section = section(invoice)
    sign = if note.note_type == "Debit", do: 1, else: -1
    sections = %{sections | hsn: absorb_hsn(lines, section == :b2b, sections.hsn, sign)}

    case section do
      :b2b ->
        entry = %{
          "ntty" => note_type(note),
          "nt_num" => note.note_number,
          "nt_dt" => format_date(note.note_date),
          "pos" => state_code(invoice.place_of_supply),
          "rchrg" => reverse_charge(invoice),
          "inv_typ" => "R",
          "val" => rupees(note.grand_total),
          "itms" => rate_lines(lines, :all_heads)
        }

        %{
          sections
          | cdnr: Map.update(sections.cdnr, invoice.client_gstin, [entry], &[entry | &1])
        }

      :b2cl ->
        entry = %{
          "typ" => "B2CL",
          "ntty" => note_type(note),
          "nt_num" => note.note_number,
          "nt_dt" => format_date(note.note_date),
          "pos" => state_code(invoice.place_of_supply),
          "val" => rupees(note.grand_total),
          "itms" => rate_lines(lines, :igst_only)
        }

        %{sections | cdnur: [entry | sections.cdnur]}

      # A note on a small consumer sale has no row of its own: it nets into Table 7.
      :b2cs ->
        %{sections | b2cs: absorb_b2cs(invoice, lines, sections.b2cs, sign)}
    end
  end

  # The invoice's lines scaled to the note's taxable value and tax, with any
  # rounding put on the first line so they add up to the note exactly. A note
  # changes value, not quantity, so its lines carry none.
  defp note_lines(%CreditNote{invoice: invoice} = note) do
    base = lines(invoice)
    whole = sum_amounts(base)
    whole_tax = whole.cgst + whole.sgst + whole.igst

    {taxable, tax} =
      if Invoice.gst_reverse_charge?(invoice),
        # The note charges no tax either; what it takes back from the
        # recipient's reverse-charge tax is its rc_tax_amount.
        do: {note.subtotal || note.grand_total || 0, note.rc_tax_amount || 0},
        else: note_amounts(note, whole.taxable, whole_tax)

    {cgst, sgst, igst} = split_tax(tax, Invoice.intra_state?(invoice))

    base
    |> Enum.map(fn line ->
      %{
        line
        | qty: Decimal.new(0),
          taxable: scale(line.taxable, taxable, whole.taxable),
          cgst: scale(line.cgst, tax, whole_tax),
          sgst: scale(line.sgst, tax, whole_tax),
          igst: scale(line.igst, tax, whole_tax)
      }
    end)
    |> settle_first(:taxable, taxable)
    |> settle_first(:cgst, cgst)
    |> settle_first(:sgst, sgst)
    |> settle_first(:igst, igst)
  end

  defp note_amounts(%CreditNote{} = note, whole_taxable, whole_tax) do
    subtotal = note.subtotal || 0
    tax = note.tax_total || 0
    total = note.grand_total || 0

    cond do
      # Within a rupee, as the total may be rounded to one.
      subtotal + tax > 0 and abs(subtotal + tax - total) <= 100 ->
        {subtotal, tax}

      # The issue-note form sends only the total, and the split then defaults
      # to the whole invoice's. The total is what was issued: split it in the
      # invoice's own proportion.
      whole_taxable + whole_tax == 0 ->
        {total, 0}

      true ->
        taxable = scale(whole_taxable, total, whole_taxable + whole_tax)
        {taxable, total - taxable}
    end
  end

  defp note_type(%CreditNote{note_type: "Debit"}), do: "D"
  defp note_type(_credit), do: "C"

  # ── Table 13 ──────────────────────────────────────────────────────────────

  # Every number used in the period, cancelled and binned ones included.
  defp doc_issue(from, to) do
    invoices =
      Invoice
      |> where([i], i.invoice_date >= ^from and i.invoice_date <= ^to)
      |> where([i], not is_nil(i.invoice_number) and i.invoice_number != "")
      |> select([i], {i.invoice_number, i.status == "Cancelled" or not is_nil(i.deleted_at)})
      |> Repo.all()

    notes =
      CreditNote
      |> where([n], n.note_date >= ^from and n.note_date <= ^to)
      |> where([n], not is_nil(n.note_number) and n.note_number != "")
      |> join(:left, [n], i in assoc(n, :invoice))
      |> select(
        [n, i],
        {n.note_type, n.note_number, n.status == "Cancelled" or not is_nil(i.deleted_at)}
      )
      |> Repo.all()

    {debit, credit} = Enum.split_with(notes, &match?({"Debit", _number, _cancelled?}, &1))

    strip = fn notes ->
      Enum.map(notes, fn {_type, number, cancelled?} -> {number, cancelled?} end)
    end

    blocks =
      [
        {1, "Invoices for outward supply", invoices},
        {4, "Debit Note", strip.(debit)},
        {5, "Credit Note", strip.(credit)}
      ]
      |> Enum.reject(fn {_num, _type, documents} -> documents == [] end)
      |> Enum.map(fn {num, type, documents} ->
        %{"doc_num" => num, "doc_typ" => type, "docs" => document_ranges(documents)}
      end)

    %{"doc_det" => blocks}
  end

  # One row per series: the number with its trailing digits taken off. A
  # prefix changed in the month starts a second row.
  defp document_ranges(documents) do
    documents
    |> Enum.group_by(fn {number, _cancelled?} -> series(number) end)
    |> Enum.sort_by(fn {prefix, _documents} -> prefix end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{_prefix, documents}, index} ->
      sorted = Enum.sort_by(documents, fn {number, _cancelled?} -> {sequence(number), number} end)
      {first, _} = List.first(sorted)
      {last, _} = List.last(sorted)
      total = length(sorted)
      cancelled = Enum.count(sorted, fn {_number, cancelled?} -> cancelled? end)

      %{
        "num" => index,
        "from" => first,
        "to" => last,
        "totnum" => total,
        "cancel" => cancelled,
        "net_issue" => total - cancelled
      }
    end)
  end

  defp series(number) do
    case Regex.run(~r/^(.*?)(\d+)$/, number) do
      [_match, prefix, _digits] -> prefix
      nil -> number
    end
  end

  defp sequence(number) do
    case Regex.run(~r/(\d+)$/, number) do
      [_match, digits] -> String.to_integer(digits)
      nil -> 0
    end
  end

  # ── Sections ──────────────────────────────────────────────────────────────

  defp finish_by(groups, key, list_key \\ "inv") do
    groups
    |> Enum.map(fn {value, entries} -> %{key => value, list_key => Enum.reverse(entries)} end)
    |> Enum.sort_by(& &1[key])
  end

  defp finish_b2cs(groups) do
    groups
    # A sale fully credited in the same month leaves nothing to report.
    |> Enum.reject(fn {_key, totals} -> Enum.all?(@amounts, &(totals[&1] == 0)) end)
    |> Enum.map(fn {{pos, rate, intra?}, totals} ->
      %{
        "sply_ty" => if(intra?, do: "INTRA", else: "INTER"),
        "pos" => pos,
        "typ" => "OE",
        "rt" => rate / 1,
        "txval" => rupees(totals.taxable),
        "iamt" => rupees(totals.igst),
        "camt" => rupees(totals.cgst),
        "samt" => rupees(totals.sgst),
        "csamt" => 0
      }
    end)
    |> Enum.sort_by(&{&1["pos"], &1["rt"], &1["sply_ty"]})
  end

  # Reported separately for B2B and B2C from the May 2025 tax period.
  defp finish_hsn(groups) do
    {b2b, b2c} = Enum.split_with(groups, fn {{b2b?, _hsn, _rate}, _totals} -> b2b? end)
    %{"hsn_b2b" => hsn_rows(b2b), "hsn_b2c" => hsn_rows(b2c)}
  end

  defp hsn_rows(groups) do
    groups
    # A sale fully credited in the same month nets to nothing.
    |> Enum.reject(fn {_key, totals} -> Enum.all?(@amounts, &(totals[&1] == 0)) end)
    |> Enum.sort_by(fn {{_b2b?, hsn, rate}, _totals} -> {hsn, rate} end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{{_b2b?, hsn, rate}, totals}, index} ->
      # A service (SAC 99…) has no quantity to report.
      {uqc, qty} =
        if String.starts_with?(hsn, "99"),
          do: {"NA", 0},
          else: {totals.uqc, Decimal.to_float(totals.qty)}

      tax = totals.cgst + totals.sgst + totals.igst

      %{
        "num" => index,
        "hsn_sc" => hsn,
        "desc" => totals.desc || "Goods or services",
        "uqc" => uqc,
        "qty" => qty,
        "rt" => rate / 1,
        "txval" => rupees(totals.taxable),
        "val" => rupees(totals.taxable + tax),
        "iamt" => rupees(totals.igst),
        "camt" => rupees(totals.cgst),
        "samt" => rupees(totals.sgst),
        "csamt" => 0
      }
    end)
  end

  # ── Line amounts ──────────────────────────────────────────────────────────

  # One map per invoice line, with its tax split into the heads. The single
  # source for every table, so they cannot disagree.
  defp lines(%Invoice{items: [_ | _] = items} = invoice) do
    intra? = Invoice.intra_state?(invoice)

    items
    |> Enum.map(fn item ->
      {cgst, sgst, igst} = split_tax(InvoiceItem.tax(item), intra?)

      %{
        hsn: presence(item.hsn_sac) || @fallback_hsn,
        rate: item.tax_rate || 0,
        desc: item.description,
        uqc: uqc(item),
        qty: Money.quantity(item.quantity) || Decimal.new(0),
        taxable: InvoiceItem.amount(item),
        cgst: cgst,
        sgst: sgst,
        igst: igst
      }
    end)
    |> settle_to_invoice(invoice)
  end

  # An invoice without line items: one line from its stored totals.
  defp lines(%Invoice{} = invoice) do
    taxable = invoice.taxable_value || 0
    cgst = head(invoice, :cgst)
    sgst = head(invoice, :sgst)
    igst = head(invoice, :igst)
    tax = cgst + sgst + igst

    [
      %{
        hsn: @fallback_hsn,
        rate: if(taxable > 0, do: round(tax * 100 / taxable), else: 0),
        desc: nil,
        uqc: "OTH",
        qty: Decimal.new(0),
        taxable: taxable,
        cgst: cgst,
        sgst: sgst,
        igst: igst
      }
    ]
  end

  # The invoice halves CGST/SGST on its total tax, the lines on their own, so
  # they can differ by a paisa a line. The last line takes that difference so
  # the heads match the invoice. A bigger gap is not rounding and is left alone.
  defp settle_to_invoice(lines, invoice) do
    Enum.reduce(
      [cgst: head(invoice, :cgst), sgst: head(invoice, :sgst), igst: head(invoice, :igst)],
      lines,
      fn {key, stored}, lines ->
        diff = (stored || 0) - Enum.sum(Enum.map(lines, &Map.fetch!(&1, key)))

        if diff != 0 and abs(diff) <= length(lines),
          do: List.update_at(lines, -1, &Map.update!(&1, key, fn value -> value + diff end)),
          else: lines
      end
    )
  end

  defp rate_lines(lines, heads) do
    lines
    |> Enum.group_by(& &1.rate)
    |> Enum.sort_by(fn {rate, _lines} -> rate end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{rate, rate_lines}, index} ->
      totals = sum_amounts(rate_lines)

      details =
        case heads do
          # B2CL is inter-state by definition: the schema takes IGST alone.
          :igst_only ->
            %{"rt" => rate / 1, "txval" => rupees(totals.taxable), "iamt" => rupees(totals.igst)}

          :all_heads ->
            %{
              "rt" => rate / 1,
              "txval" => rupees(totals.taxable),
              "iamt" => rupees(totals.igst),
              "camt" => rupees(totals.cgst),
              "samt" => rupees(totals.sgst)
            }
        end

      %{"num" => index, "itm_det" => Map.put(details, "csamt", 0)}
    end)
  end

  defp sum_amounts(lines), do: Enum.reduce(lines, Map.new(@amounts, &{&1, 0}), &add(&2, &1, 1))

  defp add(held, line, sign) do
    Enum.reduce(@amounts, held, fn key, acc ->
      Map.update(acc, key, sign * Map.fetch!(line, key), &(&1 + sign * Map.fetch!(line, key)))
    end)
  end

  defp scale(_value, _part, whole) when whole in [nil, 0], do: 0
  defp scale(value, part, whole), do: round((value || 0) * part / whole)

  # Puts any rounding difference on the first line, so lines sum to the total.
  defp settle_first([first | rest] = lines, key, total) do
    diff = total - Enum.sum(Enum.map(lines, &Map.fetch!(&1, key)))
    [Map.update!(first, key, &(&1 + diff)) | rest]
  end

  # A head's tax as GSTR-1 reports it: what the invoice charged, or on a
  # reverse-charge invoice the tax the recipient pays (rchrg "Y").
  defp head(%Invoice{} = invoice, head),
    do: QuantumBilling.EInvoice.Payload.reported_tax(invoice, head)

  defp split_tax(tax, true) do
    half = div(tax, 2)
    {half, half, 0}
  end

  defp split_tax(tax, false), do: {0, 0, tax}

  # ── Shared shaping ────────────────────────────────────────────────────────

  defp registered_buyer?(%Invoice{client_gstin: gstin, invoice_type: type}) do
    presence(gstin) != nil and type in [nil, "Tax Invoice", "Export Invoice", "Debit Note"]
  end

  defp reverse_charge(%Invoice{reverse_charge: true}), do: "Y"
  defp reverse_charge(_invoice), do: "N"

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

  # The portal schema takes rupees as JSON numbers; two decimals survive a float.
  defp rupees(nil), do: 0
  defp rupees(paise) when is_integer(paise), do: paise / 100

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
