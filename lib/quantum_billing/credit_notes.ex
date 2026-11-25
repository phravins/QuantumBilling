defmodule QuantumBilling.CreditNotes do
  @moduledoc """
  Context module for managing Credit Notes and Debit Notes.
  """
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias QuantumBilling.Compliance
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Money
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  # Notes on binned invoices are left out; a left join keeps notes with no invoice.
  def list_credit_notes do
    CreditNote
    |> join(:left, [n], i in assoc(n, :invoice))
    |> where([_n, i], is_nil(i.deleted_at))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Repo.preload([:invoice, :client])
  end

  @doc """
  One API page of notes, newest first, keyset-paged below `:before_id`
  (`Paging.keyset/3`). Notes on binned invoices are excluded.

  Options: `:before_id`, `:per_page` (1..100), `:invoice_id`.
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, 25) |> max(1) |> min(100)

    listed_query()
    |> invoice_where(Keyword.get(opts, :invoice_id))
    |> QuantumBilling.Paging.keyset(Keyword.get(opts, :before_id), per_page)
    |> then(fn result -> %{result | rows: Repo.preload(result.rows, :invoice)} end)
  end

  @doc "A note by id, on the same terms as `page/1` lists it, or `nil`."
  def get_listed_credit_note(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        listed_query() |> where([n], n.id == ^id) |> Repo.one() |> Repo.preload(:invoice)

      _not_an_id ->
        nil
    end
  end

  defp listed_query do
    from n in CreditNote,
      left_join: i in assoc(n, :invoice),
      where: is_nil(i.deleted_at)
  end

  defp invoice_where(query, nil), do: query
  defp invoice_where(query, invoice_id), do: where(query, [n], n.invoice_id == ^invoice_id)

  def get_credit_note!(id) do
    CreditNote
    |> Repo.get!(id)
    |> Repo.preload([:invoice, :client])
  end

  @doc """
  Raises a note against `invoice`. Amounts are rupees.

  A credit note can be at most `creditable/1`, and is refused on a cancelled
  or binned invoice. A missing total defaults to what is left to credit (a
  debit note, to the invoice's total); a missing taxable value or tax is taken
  from the total in the invoice's own proportion. A credit note that leaves
  nothing to credit on an unpaid invoice marks it "Credited"; a debit note on
  a credited one makes it owed again.

  The note takes the next number of its type's series (Rule 53 of the CGST
  Rules: consecutive, at most 16 characters) and today's date where the
  business is.
  """
  def create_credit_note_for_invoice(%Invoice{} = invoice, attrs \\ %{}) do
    note_type = attr(attrs, :note_type) || "Credit"

    # Outside the transaction: creating the row inside it deadlocks concurrent callers.
    Settings.ensure_organization()

    Multi.new()
    # Locked so two notes cannot take the same number. Invoices lock the same
    # row the same way, so the two never wait on each other in a cycle. Every
    # note waits here, so the limit read below cannot be raced either.
    |> Multi.run(:organization, fn repo, _changes ->
      case repo.one(from o in Organization, order_by: [asc: o.id], limit: 1, lock: "FOR UPDATE") do
        nil -> {:ok, %Organization{}}
        organization -> {:ok, organization}
      end
    end)
    # Re-read under the lock that cancelling and payment take, so the note
    # sees the invoice as it is now, not as the caller loaded it.
    |> Multi.run(:invoice, fn repo, _changes ->
      {:ok, repo.one(from i in Invoice, where: i.id == ^invoice.id, lock: "FOR UPDATE")}
    end)
    |> Multi.run(:creditable, fn repo, %{invoice: locked} ->
      {:ok, if(locked, do: creditable(repo, locked), else: 0)}
    end)
    |> Multi.insert(:note, fn %{organization: org, invoice: locked, creditable: creditable} ->
      current = locked || invoice

      trusted = %{
        note_number: Settings.next_note_number(org, series(note_type)),
        note_date: Compliance.local_date(DateTime.utc_now(), org.timezone),
        creditable: creditable,
        currency: current.currency
      }

      %CreditNote{tax_regime: current.tax_regime || "gst"}
      |> CreditNote.changeset(note_params(current, attrs, note_type, creditable), trusted)
      |> refuse_closed_invoice(locked)
      |> put_breakdown(current)
    end)
    |> Multi.run(:advance_number, fn repo, %{organization: organization, note: note} ->
      field = next_number_field(note.note_type)

      organization
      |> Ecto.Changeset.change(%{field => (Map.get(organization, field) || 1) + 1})
      |> repo.insert_or_update()
    end)
    |> Multi.run(:invoice_status, fn repo, changes ->
      settle_status(repo, changes.invoice, changes.creditable, changes.note)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{note: note, invoice: locked, invoice_status: changed}} ->
        if changed, do: QuantumBilling.Invoices.broadcast_change(changed, :invoice_changed)
        QuantumBilling.Webhooks.publish("credit_note.created", note.id)
        audit_created(note, locked || invoice)
        {:ok, note}

      {:error, :note, changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp audit_created(note, invoice) do
    action = if note.note_type == "Debit", do: :debit_note_created, else: :credit_note_created

    QuantumBilling.Audit.log_event(action, "CreditNote", note.id,
      label: note.note_number,
      details: %{
        number: note.note_number,
        invoice_id: invoice.id,
        invoice_number: invoice.invoice_number,
        client_name: invoice.client_name,
        total: QuantumBillingWeb.Format.money(note.grand_total, invoice.currency),
        reason: note.reason
      }
    )
  end

  @doc """
  What can still be credited on `invoice`, in paise: its total, plus its debit
  notes, less its credit notes. Cancelled notes do not count.
  """
  def creditable(%Invoice{} = invoice), do: creditable(Repo, invoice)

  defp creditable(repo, %Invoice{id: id, grand_total: grand_total}) do
    net =
      repo.one(
        from n in CreditNote,
          where: n.invoice_id == ^id and n.status != "Cancelled",
          select:
            type(
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'Credit' THEN -? ELSE ? END",
                    n.note_type,
                    n.grand_total,
                    n.grand_total
                  )
                ),
                0
              ),
              :integer
            )
      )

    max((grand_total || 0) + net, 0)
  end

  defp attr(attrs, key), do: Map.get(attrs, to_string(key)) || Map.get(attrs, key)

  defp note_params(invoice, attrs, note_type, creditable) do
    grand_total = attr(attrs, :grand_total) || default_total(note_type, invoice, creditable)
    {subtotal, tax_total} = split(attrs, grand_total, invoice)

    params = %{
      note_type: note_type,
      invoice_id: invoice.id,
      client_id: invoice.client_id,
      reason: attr(attrs, :reason) || "Order modification / refund",
      subtotal: subtotal,
      tax_total: tax_total,
      grand_total: grand_total,
      status: "Issued"
    }

    case attr(attrs, :custom_fields) do
      values when is_map(values) -> Map.put(params, :custom_fields, values)
      _none -> params
    end
  end

  defp default_total("Credit", invoice, creditable),
    do: Money.to_decimal(creditable, invoice.currency)

  defp default_total(_debit, invoice, _creditable),
    do: Money.to_decimal(invoice.grand_total, invoice.currency)

  # The form sends only the total, so the taxable value and tax are taken from
  # it in the invoice's own proportion, so the three always add up. A value
  # that does not parse is passed on for the changeset to refuse.
  defp split(attrs, grand_total, invoice) do
    subtotal = attr(attrs, :subtotal)
    tax_total = attr(attrs, :tax_total)
    currency = invoice.currency
    parse = &Money.parse(&1, currency)
    decimal = &Money.to_decimal(&1, currency)

    case {parse.(grand_total), subtotal && parse.(subtotal), tax_total && parse.(tax_total)} do
      {_total, {:ok, _subtotal}, {:ok, _tax}} ->
        {subtotal, tax_total}

      {{:ok, total}, nil, nil} ->
        taxable = proportion(total, invoice)
        {decimal.(taxable), decimal.(total - taxable)}

      {{:ok, total}, {:ok, taxable}, nil} ->
        {subtotal, decimal.(total - taxable)}

      {{:ok, total}, nil, {:ok, tax}} ->
        {decimal.(total - tax), tax_total}

      _unparsed ->
        {subtotal || 0, tax_total || 0}
    end
  end

  defp proportion(total, invoice) do
    taxable = invoice.taxable_value || 0

    case taxable + invoice_tax(invoice) do
      0 -> total
      whole -> round(total * taxable / whole)
    end
  end

  defp refuse_closed_invoice(changeset, %Invoice{status: "Cancelled"}),
    do: Ecto.Changeset.add_error(changeset, :invoice_id, "is cancelled, so no note can be issued")

  defp refuse_closed_invoice(changeset, %Invoice{deleted_at: nil}), do: changeset

  defp refuse_closed_invoice(changeset, _binned_or_gone),
    do:
      Ecto.Changeset.add_error(changeset, :invoice_id, "is in the Bin, so no note can be issued")

  # Paid and cancelled invoices keep their status; a paid one's credit is the
  # client's to use (see `Invoices.outstanding_by_client/1`).
  defp settle_status(repo, %Invoice{status: status} = invoice, before, note) do
    left =
      if note.note_type == "Credit",
        do: before - note.grand_total,
        else: before + note.grand_total

    new_status =
      cond do
        status in ["Paid", "Cancelled"] -> nil
        status == "Credited" and left > 0 -> reopened_status(invoice)
        status != "Credited" and left <= 0 -> "Credited"
        true -> nil
      end

    case new_status do
      nil -> {:ok, nil}
      new_status -> invoice |> Ecto.Changeset.change(status: new_status) |> repo.update()
    end
  end

  # What a credited invoice was before: registered with the IRP, or not.
  defp reopened_status(%Invoice{irn: irn}) when is_binary(irn) and irn != "",
    do: "E-Invoice Generated"

  defp reopened_status(_invoice), do: "Draft"

  # An unknown type still takes a number, and the changeset then refuses it.
  defp series("Debit"), do: "Debit"
  defp series(_credit_or_unknown), do: "Credit"

  defp next_number_field("Debit"), do: :debit_note_next_number
  defp next_number_field(_credit), do: :credit_note_next_number

  defp invoice_tax(invoice) do
    (invoice.cgst_amount || 0) + (invoice.sgst_amount || 0) + (invoice.igst_amount || 0) +
      (invoice.cess_amount || 0) + (invoice.vat_amount || 0)
  end

  # The invoice's VAT breakdown, scaled to the note's own taxable value and tax.
  defp put_breakdown(changeset, %Invoice{tax_breakdown: [_ | _] = breakdown} = invoice) do
    taxable = Ecto.Changeset.get_field(changeset, :subtotal) || 0
    tax = Ecto.Changeset.get_field(changeset, :tax_total) || 0

    scaled =
      breakdown
      |> Enum.map(fn line ->
        line
        |> Map.put("taxable", scale(line["taxable"], taxable, invoice.taxable_value))
        |> Map.put("tax", scale(line["tax"], tax, invoice_tax(invoice)))
      end)
      |> settle("taxable", taxable)
      |> settle("tax", tax)

    Ecto.Changeset.put_change(changeset, :tax_breakdown, scaled)
  end

  defp put_breakdown(changeset, _invoice), do: changeset

  defp scale(_value, _part, whole) when whole in [nil, 0], do: 0
  defp scale(value, part, whole), do: round((value || 0) * part / whole)

  # Puts any rounding difference on the first line, so lines sum to the total.
  defp settle([first | rest] = lines, key, total) do
    diff = total - Enum.sum(Enum.map(lines, &(&1[key] || 0)))
    [Map.update(first, key, diff, &(&1 + diff)) | rest]
  end
end
