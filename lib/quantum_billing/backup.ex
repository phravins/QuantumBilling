defmodule QuantumBilling.Backup do
  @moduledoc """
  Exports the business data as JSON, and restores it.

  ## What was wrong with the previous pair

  The export handed Ecto structs to `Jason.encode!/1`, which raises on
  `__meta__` — so the download button returned a 500 every time and no backup
  had ever been produced. Once the encrypted credential columns arrived it
  would also have written the SMTP password and API secrets into a plaintext
  file that gets emailed around.

  The restore was worse. It deleted invoices, line items, templates, recurring
  profiles, credit notes and the audit trail, and then re-inserted only the
  clients and a handful of settings fields. Restoring a backup destroyed the
  invoices it was supposed to bring back.

  ## What it does now

  Export walks each table and writes explicit field maps — no structs, no
  `__meta__`, no associations. Credentials are deliberately omitted: a backup
  is a file people copy around, and a mail password does not belong in one.
  They are re-entered in Settings after a restore, which the file says.

  Restore replaces the business tables inside a single transaction, in an order
  the foreign keys allow, and returns what it wrote. Anything it cannot insert
  aborts the whole thing, so a half-restored database is not a state this can
  produce. Users, sessions and two-factor enrolments are never touched: they
  are how you are signed in while restoring.

  ## Both directions stream

  At fifty thousand invoices the previous export built a hundred-megabyte
  string in memory and took half a minute before the first byte reached the
  browser — long enough for the request to time out with nothing downloaded.
  `stream_json/1` emits the file table by table, row by row, from one
  transaction: constant memory, a consistent snapshot, and bytes moving
  immediately.

  Restore inserts in batches for a harder reason: `INSERT` takes at most 65,535
  parameters, so a single `insert_all` of fifty thousand invoices is not slow —
  it is rejected outright, and the restore fails at exactly the size where it
  matters.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Templates.InvoiceTemplate

  @version "2.0"

  # Read from the settings row, minus the credentials. `Encrypted.Secret`
  # columns decrypt on load, so including them would put live secrets in the
  # file in plaintext.
  @organization_fields ~w(company_name trade_name address city pincode phone email gstin pan
                          state currency financial_year timezone date_format invoice_prefix
                          invoice_next_number invoice_number_padding invoice_due_days
                          invoice_terms ewb_transport_mode ewb_transporter_id ewb_threshold_value
                          ewb_auto_generate default_gst_rate cess_enabled composition_scheme
                          tds_enabled notify_invoice_created notify_ewb_generated
                          notify_filing_reminders reminder_lead_days language rows_per_page
                          upi_vpa upi_payee_name razorpay_key_id irp_username irp_client_id
                          webhook_url allowed_ips session_timeout_minutes enforce_2fa
                          audit_retention_days doc_logo_path)a

  @client_fields ~w(id client_type name display_name gstin pan legal_name business_type category
                    phone_country_code phone email billing_line1 billing_line2 billing_city
                    billing_state billing_pin shipping_same_as_billing shipping_line1
                    shipping_line2 shipping_city shipping_state shipping_pin credit_limit
                    payment_terms_days opening_balance notes status outstanding)a

  @invoice_fields ~w(id invoice_number invoice_type invoice_date due_date payment_terms
                     place_of_supply client_id client_name client_gstin client_pan
                     client_billing_address client_email client_state client_city client_pincode
                     company_name company_address company_gstin company_state remarks terms
                     total_items total_quantity taxable_value cgst_amount sgst_amount igst_amount
                     cess_amount round_off grand_total status irn ack_number ack_date
                     signed_qr_code signed_invoice ewb_number ewb_date ewb_valid_until distance_km
                     transporter_id transporter_name vehicle_number mode_of_transport currency
                     exchange_rate export_type lut_number razorpay_payment_link_id
                     razorpay_payment_url razorpay_payment_id public_token template_id
                     layout_xml)a

  @item_fields ~w(id invoice_id description hsn_sac quantity unit rate tax_rate amount position)a

  @template_fields ~w(id name layout_xml accent is_default archived_at)a

  @profile_fields ~w(id title frequency next_run_date status auto_send_email client_id
                     items_json)a

  @credit_note_fields ~w(id note_number note_type invoice_id client_id reason subtotal tax_total
                         grand_total status)a

  @audit_fields ~w(id user_id action resource_type resource_id details ip_address inserted_at)a

  # Every table in the file, in the order it is written and restored. Parents
  # before children, so a restore never inserts a row whose foreign key has
  # not arrived yet.
  # Keyed by atom rather than by string: the JSON name is derived from it,
  # while going the other way would mean `String.to_existing_atom/1` on a name
  # that may never have been an atom in this release.
  @sections [
    {:clients, Client, @client_fields},
    {:templates, InvoiceTemplate, @template_fields},
    {:invoices, Invoice, @invoice_fields},
    {:invoice_items, InvoiceItem, @item_fields},
    {:recurring_profiles, RecurringProfile, @profile_fields},
    {:credit_notes, CreditNote, @credit_note_fields},
    {:audit_logs, AuditLog, @audit_fields}
  ]

  # Postgres accepts at most 65,535 bind parameters per statement. Batches are
  # sized from the widest row so the count stays comfortably under it.
  @max_parameters 20_000

  # How many rows `Repo.stream/2` fetches from its cursor at a time.
  @stream_rows 500

  @doc """
  The whole business dataset as a JSON string.

  Convenient, and fine for a small installation — but it holds the entire file
  in memory, so anything serving a download should use `stream_json/1`.
  """
  def export_json do
    {:ok, iodata} = stream_json(fn chunk, acc -> [acc | chunk] end, [])

    IO.iodata_to_binary(iodata)
  end

  @doc """
  Streams the backup as JSON, folding each chunk into `acc` with `fun`.

  Runs inside one transaction, so the file is a consistent snapshot rather than
  seven tables read at seven different moments.
  """
  def stream_json(fun, acc) when is_function(fun, 2) do
    Repo.transaction(
      fn ->
        acc = fun.(header(), acc)

        acc =
          Enum.reduce(@sections, acc, fn {key, schema, fields}, acc ->
            acc = fun.([",\"", Atom.to_string(key), "\":["], acc)

            {acc, _first?} =
              schema
              |> order_by(asc: :id)
              |> Repo.stream(max_rows: @stream_rows)
              |> Enum.reduce({acc, true}, fn row, {acc, first?} ->
                separator = if first?, do: [], else: [","]
                encoded = Jason.encode_to_iodata!(Map.take(row, fields))

                {fun.([separator, encoded], acc), false}
              end)

            fun.(["]"], acc)
          end)

        fun.(["}"], acc)
      end,
      timeout: :infinity
    )
  end

  defp header do
    organization =
      case organization_row() do
        nil -> "null"
        row -> Jason.encode_to_iodata!(row)
      end

    [
      "{\"version\":",
      Jason.encode_to_iodata!(@version),
      ",\"generated_at\":",
      Jason.encode_to_iodata!(DateTime.utc_now() |> DateTime.to_iso8601()),
      # Said in the file itself, because whoever restores it six months from
      # now will not be whoever read the release notes.
      ",\"note\":",
      Jason.encode_to_iodata!(
        "Credentials (SMTP password, API secrets, webhook secret) are deliberately " <>
          "excluded and must be re-entered in Settings after restoring. Users and " <>
          "sign-in details are not included and are never touched by a restore."
      ),
      ",\"organization\":",
      organization
    ]
  end

  @doc """
  Counts of what a backup contains, for the confirmation shown before a restore.
  """
  def summarize(%{} = data) do
    Map.new(@sections, fn {key, _schema, _fields} ->
      name = Atom.to_string(key)

      {name, data |> Map.get(name, []) |> length()}
    end)
  end

  @doc """
  Replaces the business data with the contents of `json_string`.

  Returns `{:ok, counts}` or `{:error, message}`. Everything happens in one
  transaction: a backup that fails halfway leaves the database as it was.
  """
  def restore_json(json_string) when is_binary(json_string) do
    with {:ok, data} <- decode(json_string),
         :ok <- check_version(data) do
      # No timeout: restoring a year of invoices is one long transaction by
      # nature, and the pool's fifteen-second default aborted it at exactly the
      # size where a restore is worth having.
      Repo.transaction(
        fn ->
          # Children first: invoice items and credit notes reference invoices,
          # invoices reference clients.
          Repo.delete_all(AuditLog)
          Repo.delete_all(CreditNote)
          Repo.delete_all(InvoiceItem)
          Repo.delete_all(Invoice)
          Repo.delete_all(RecurringProfile)
          Repo.delete_all(InvoiceTemplate)
          Repo.delete_all(Client)

          counts =
            Map.new(@sections, fn {key, schema, fields} ->
              {key, insert_all!(schema, data[Atom.to_string(key)], fields)}
            end)

          restore_organization!(data["organization"])

          # The rows carry their original ids, so every sequence has to be moved
          # past them. Without this the next insert reuses id 1 and fails on the
          # primary key.
          Enum.each(
            ~w(clients invoices invoice_items invoice_templates recurring_profiles credit_notes
               audit_logs),
            &resync_sequence/1
          )

          counts
        end,
        timeout: :infinity
      )
      |> case do
        {:ok, counts} -> {:ok, counts}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def restore_json(_not_a_string), do: {:error, "No backup file was provided."}

  defp decode(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, _not_an_object} -> {:error, "That file is not a QuantumBilling backup."}
      {:error, _reason} -> {:error, "That file is not valid JSON."}
    end
  end

  # 1.0 files were produced by an exporter that raised before writing anything,
  # so none exist; anything claiming to be one is not a backup of this system.
  defp check_version(%{"version" => @version}), do: :ok

  defp check_version(%{"version" => other}),
    do:
      {:error,
       "Backup version #{other} cannot be restored by this release (expected #{@version})."}

  defp check_version(_data), do: {:error, "That file is not a QuantumBilling backup."}

  defp organization_row do
    case Repo.one(from o in Organization, order_by: [asc: o.id], limit: 1) do
      nil -> nil
      organization -> Map.take(organization, @organization_fields)
    end
  end

  # `insert_all/3` rather than changesets: a backup is data this application
  # already validated on the way in, and re-validating it would reject rows
  # whose rules have since changed — which is precisely when a restore matters.
  defp insert_all!(_schema, nil, _fields), do: 0
  defp insert_all!(_schema, [], _fields), do: 0

  defp insert_all!(schema, rows, fields) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    has_timestamps? = :inserted_at in schema.__schema__(:fields)
    has_updated_at? = :updated_at in schema.__schema__(:fields)

    # One statement per batch. A single `insert_all` of every row would exceed
    # Postgres's 65,535-parameter ceiling on any real dataset and be rejected
    # outright — the restore failed precisely when there was something to
    # restore.
    batch_size = max(div(@max_parameters, max(length(fields) + 2, 1)), 1)

    rows
    |> Stream.map(fn row ->
      row
      |> cast_row(schema, fields)
      |> then(fn entry ->
        entry
        |> maybe_put(has_timestamps?, :inserted_at, Map.get(entry, :inserted_at) || now)
        |> maybe_put(has_updated_at?, :updated_at, now)
      end)
    end)
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce(0, fn batch, inserted ->
      {count, _} = Repo.insert_all(schema, batch)
      inserted + count
    end)
  end

  defp insert_all!(_schema, other, _fields) do
    Repo.rollback("Expected a list of rows, got #{inspect(other)}.")
  end

  defp maybe_put(map, false, _key, _value), do: map
  defp maybe_put(map, true, key, value), do: Map.put(map, key, value)

  # JSON gives back strings; the database wants dates, decimals and maps. Ecto's
  # own type casting is what knows which is which, per column.
  defp cast_row(row, schema, fields) when is_map(row) do
    for field <- fields, into: %{} do
      value = Map.get(row, Atom.to_string(field), Map.get(row, field))

      case Ecto.Type.cast(schema.__schema__(:type, field), value) do
        {:ok, cast} -> {field, cast}
        :error -> Repo.rollback("#{schema}.#{field} could not read #{inspect(value)}.")
      end
    end
  end

  defp cast_row(other, schema, _fields) do
    Repo.rollback("#{schema} expected an object per row, got #{inspect(other)}.")
  end

  defp restore_organization!(nil), do: :ok

  defp restore_organization!(attrs) when is_map(attrs) do
    organization =
      Repo.one(from o in Organization, order_by: [asc: o.id], limit: 1) || %Organization{}

    changes =
      for field <- @organization_fields,
          Map.has_key?(attrs, Atom.to_string(field)),
          into: %{} do
        value = Map.get(attrs, Atom.to_string(field))

        case Ecto.Type.cast(Organization.__schema__(:type, field), value) do
          {:ok, cast} -> {field, cast}
          :error -> Repo.rollback("organization.#{field} could not read #{inspect(value)}.")
        end
      end

    organization
    |> Ecto.Changeset.change(changes)
    |> Repo.insert_or_update()
    |> case do
      {:ok, _organization} ->
        :ok

      {:error, changeset} ->
        Repo.rollback("Settings could not be restored: #{inspect(changeset.errors)}")
    end
  end

  defp restore_organization!(_other),
    do: Repo.rollback("Settings in the backup are not an object.")

  defp resync_sequence(table) do
    Repo.query!(
      """
      SELECT setval(
        pg_get_serial_sequence($1, 'id'),
        COALESCE((SELECT MAX(id) FROM #{table}), 0) + 1,
        false
      )
      """,
      [table]
    )
  end
end
