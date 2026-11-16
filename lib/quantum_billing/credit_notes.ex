defmodule QuantumBilling.CreditNotes do
  @moduledoc """
  Context module for managing Credit Notes and Debit Notes.
  """
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias QuantumBilling.Repo
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Money
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
  Raises a note against `invoice`. Amounts are rupees; missing ones default to the invoice's.
  """
  def create_credit_note_for_invoice(%Invoice{} = invoice, attrs \\ %{}) do
    raw_type = Map.get(attrs, "note_type") || Map.get(attrs, :note_type, "Credit")
    note_type = if to_string(raw_type) |> String.downcase() == "debit", do: "Debit", else: "Credit"

    # Outside the transaction: creating the row inside it deadlocks concurrent callers.
    organization = Settings.ensure_organization() || %Organization{}

    subtotal =
      Map.get(attrs, "subtotal") ||
        Map.get(attrs, :subtotal, Money.to_rupees_decimal(invoice.taxable_value))

    tax_total =
      Map.get(attrs, "tax_total") ||
        Map.get(
          attrs,
          :tax_total,
          Money.to_rupees_decimal(invoice_tax(invoice))
        )

    grand_total =
      Map.get(attrs, "grand_total") ||
        Map.get(attrs, :grand_total, Money.to_rupees_decimal(invoice.grand_total))

    reason = Map.get(attrs, "reason") || Map.get(attrs, :reason, "Order modification / refund")

    Multi.new()
    |> Multi.run(:organization, fn repo, _changes ->
      case repo.one(from o in Organization, order_by: [asc: o.id], limit: 1, lock: "FOR UPDATE") do
        nil -> {:ok, organization}
        locked -> {:ok, locked}
      end
    end)
    |> Multi.insert(:credit_note, fn %{organization: locked} ->
      note_number =
        if note_type == "Credit" do
          Settings.next_credit_note_number(locked)
        else
          Settings.next_debit_note_number(locked)
        end

      local_today =
        DateTime.utc_now()
        |> QuantumBilling.Compliance.local_time(locked.timezone || organization.timezone)
        |> NaiveDateTime.to_date()

      note_date = Map.get(attrs, "note_date") || Map.get(attrs, :note_date, local_today)

      params = %{
        note_number: note_number,
        note_type: note_type,
        note_date: note_date,
        invoice_id: invoice.id,
        client_id: invoice.client_id,
        reason: reason,
        subtotal: subtotal,
        tax_total: tax_total,
        grand_total: grand_total,
        status: "Issued"
      }

      params =
        case Map.get(attrs, "custom_fields", Map.get(attrs, :custom_fields)) do
          values when is_map(values) -> Map.put(params, :custom_fields, values)
          _none -> params
        end

      %CreditNote{tax_regime: invoice.tax_regime || "gst"}
      |> CreditNote.changeset(params)
      |> put_breakdown(invoice)
    end)
    |> Multi.run(:advance_number, fn repo, %{organization: locked} ->
      changes =
        if note_type == "Credit" do
          %{credit_note_next_number: (locked.credit_note_next_number || 1) + 1}
        else
          %{debit_note_next_number: (locked.debit_note_next_number || 1) + 1}
        end

      locked
      |> Ecto.Changeset.change(changes)
      |> repo.insert_or_update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{credit_note: note}} ->
        QuantumBilling.Webhooks.publish("credit_note.created", note.id)
        {:ok, note}

      {:error, :credit_note, changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp invoice_tax(invoice) do
    (invoice.cgst_amount || 0) + (invoice.sgst_amount || 0) + (invoice.igst_amount || 0) +
      (invoice.vat_amount || 0)
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
