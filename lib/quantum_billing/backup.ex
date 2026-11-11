defmodule QuantumBilling.Backup do
  @moduledoc """
  Exports the business data as JSON, and restores it.

  Export writes explicit field maps per table and leaves out credentials (they
  are re-entered after a restore). It streams from one transaction, so the file
  is a consistent snapshot. Restore replaces the business tables in one
  transaction, in foreign-key order and in batches. Users and sessions are never
  touched.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Compliance.Task, as: ComplianceTask
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.CustomFields.FieldDefinition
  alias QuantumBilling.DesignAssets
  alias QuantumBilling.DesignAssets.DesignAsset
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.PartBUpdate
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Money.Paise
  alias QuantumBilling.Recurring.RecurringProfile
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.TaxRates.TaxRate
  alias QuantumBilling.Templates.InvoiceTemplate

  @version "3.2"

  # Older files are still restored; upgrade/1 brings them to the current shape.
  @readable_versions ["2.0", "2.1", "3.0", "3.1", @version]

  # Before 3.2 every record was GST; these are the VAT columns' values for it.
  @gst_defaults %{
    "invoices" => %{
      "tax_regime" => "gst",
      "vat_amount" => 0,
      "tax_breakdown" => [],
      "reverse_charge" => false,
      "prices_include_tax" => false,
      "round_to_whole_units" => true
    },
    "credit_notes" => %{"tax_regime" => "gst", "tax_breakdown" => []},
    "clients" => %{"country" => "IN"}
  }

  # Before 3.0 these held whole rupees (credit notes, two-place decimals); now paise.
  @rupee_fields %{
    "invoices" =>
      ~w(taxable_value cgst_amount sgst_amount igst_amount cess_amount round_off grand_total),
    "invoice_items" => ~w(rate amount),
    "clients" => ~w(credit_limit opening_balance outstanding),
    "credit_notes" => ~w(subtotal tax_total grand_total)
  }

  # Credentials are excluded, and so are sign-in rules: they belong to the installation.
  @organization_fields ~w(company_name trade_name address city pincode phone email gstin pan
                          state currency financial_year timezone date_format invoice_prefix
                          invoice_next_number invoice_number_padding invoice_due_days
                          invoice_terms ewb_transport_mode ewb_transporter_id ewb_threshold_value
                          ewb_auto_generate default_gst_rate cess_enabled composition_scheme
                          tds_enabled notify_invoice_created notify_ewb_generated
                          notify_filing_reminders reminder_lead_days language rows_per_page
                          upi_vpa upi_payee_name razorpay_key_id irp_username irp_client_id
                          audit_retention_days doc_logo_path bank_account_name bank_name
                          bank_account_number bank_ifsc bank_branch tax_regime vat_number
                          vat_country prices_include_tax round_to_whole_units)a

  @client_fields ~w(id client_type name display_name gstin pan legal_name business_type category
                    phone_country_code phone email billing_line1 billing_line2 billing_city
                    billing_state billing_pin shipping_same_as_billing shipping_line1
                    shipping_line2 shipping_city shipping_state shipping_pin credit_limit
                    payment_terms_days opening_balance notes status outstanding deleted_at
                    custom_fields tax_number country)a

  @invoice_fields ~w(id invoice_number invoice_type invoice_date due_date payment_terms
                     place_of_supply client_id client_name client_gstin client_pan
                     client_billing_address client_email client_state client_city client_pincode
                     company_name company_address company_gstin company_state remarks terms
                     total_items total_quantity taxable_value cgst_amount sgst_amount igst_amount
                     cess_amount round_off grand_total status irn ack_number ack_date
                     signed_qr_code signed_invoice irn_mode currency
                     exchange_rate export_type lut_number razorpay_payment_link_id
                     razorpay_payment_url razorpay_payment_id public_token template_id
                     layout_xml deleted_at custom_fields tax_regime vat_amount tax_breakdown
                     company_tax_number client_tax_number reverse_charge prices_include_tax
                     round_to_whole_units)a

  @item_fields ~w(id invoice_id description hsn_sac quantity unit rate tax_rate amount position
                  custom_fields tax_rate_id tax_rate_bp tax_category tax_name)a

  @e_way_bill_fields ~w(id invoice_id ewb_number ewb_date valid_until status distance_km
                        mode_of_transport vehicle_number transporter_id transporter_name
                        cancelled_at cancellation_reason deleted_at portal_mode custom_fields)a

  @part_b_fields ~w(id e_way_bill_id vehicle_number mode_of_transport place reason updated_on)a

  @template_fields ~w(id name layout_xml accent is_default archived_at)a

  # deleted_at travels with the backup so binned records stay in the Bin.
  @profile_fields ~w(id title frequency next_run_date status auto_send_email client_id
                     items_json deleted_at custom_fields)a

  @credit_note_fields ~w(id note_number note_type invoice_id client_id reason subtotal tax_total
                         grand_total status custom_fields tax_regime tax_breakdown)a

  @tax_rate_fields ~w(id name category rate_bp exemption_reason is_default position archived_at
                      inserted_at)a

  @field_definition_fields ~w(id object key label type options required help_text position
                              show_in_list filterable show_on_invoice include_in_api archived_at
                              inserted_at)a

  # Which uploaded images this business may show: its letterheads and stamps.
  @design_asset_fields ~w(id path kind inserted_at)a

  @audit_fields ~w(id user_id action resource_type resource_id details ip_address inserted_at)a

  # No author: the file may be restored where that user doesn't exist. Private
  # tasks and "email me" are skipped for the same reason.
  @compliance_task_fields ~w(id title notes category custom_category due_date kind status
                             completed_at remind_days_before remind_at repeat reminded_at
                             inserted_at)a

  # Parents before children, so foreign keys resolve on restore.
  @sections [
    {:field_definitions, FieldDefinition, @field_definition_fields},
    {:tax_rates, TaxRate, @tax_rate_fields},
    {:clients, Client, @client_fields},
    {:templates, InvoiceTemplate, @template_fields},
    {:design_assets, DesignAsset, @design_asset_fields},
    {:invoices, Invoice, @invoice_fields},
    {:invoice_items, InvoiceItem, @item_fields},
    {:e_way_bills, EWayBill, @e_way_bill_fields},
    {:e_way_bill_part_b_updates, PartBUpdate, @part_b_fields},
    {:recurring_profiles, RecurringProfile, @profile_fields},
    {:credit_notes, CreditNote, @credit_note_fields},
    {:compliance_tasks, ComplianceTask, @compliance_task_fields},
    {:audit_logs, AuditLog, @audit_fields}
  ]

  # Postgres allows at most 65,535 bind parameters per statement.
  @max_parameters 20_000

  @stream_rows 500

  @doc "The whole backup as a JSON string. Holds it all in memory; downloads use `stream_json/1`."
  def export_json do
    {:ok, iodata} = stream_json(fn chunk, acc -> [acc | chunk] end, [])

    IO.iodata_to_binary(iodata)
  end

  @doc """
  Streams the backup as JSON, folding each chunk into `acc` with `fun`, inside one transaction.
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
              |> exported()
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

  defp exported(ComplianceTask), do: where(ComplianceTask, [t], not t.private)
  defp exported(schema), do: schema

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
  Replaces the business data with `json_string` in one transaction: `{:ok, counts}` or `{:error, message}`.
  """
  def restore_json(json_string) when is_binary(json_string) do
    with {:ok, data} <- decode(json_string),
         :ok <- check_version(data) do
      data = data |> upgrade() |> keep_valid_assets() |> keep_valid_definitions()

      # No timeout: a large restore is one long transaction.
      Repo.transaction(
        fn ->
          # Children first.
          Repo.delete_all(AuditLog)
          Repo.delete_all(ComplianceTask)
          Repo.delete_all(CreditNote)
          Repo.delete_all(InvoiceItem)
          Repo.delete_all(PartBUpdate)
          Repo.delete_all(EWayBill)
          Repo.delete_all(Invoice)
          Repo.delete_all(RecurringProfile)
          Repo.delete_all(InvoiceTemplate)
          Repo.delete_all(DesignAsset)
          Repo.delete_all(Client)
          Repo.delete_all(TaxRate)
          Repo.delete_all(FieldDefinition)

          counts =
            Map.new(@sections, fn {key, schema, fields} ->
              {key, insert_all!(schema, data[Atom.to_string(key)], fields)}
            end)

          restore_organization!(data["organization"])

          # Rows keep their ids, so move every sequence past them.
          Enum.each(
            ~w(field_definitions tax_rates clients invoices invoice_items e_way_bills e_way_bill_part_b_updates
               invoice_templates design_assets recurring_profiles credit_notes compliance_tasks
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

  # Only well-formed asset rows are restored; others are dropped.
  defp keep_valid_assets(%{"design_assets" => rows} = data) when is_list(rows) do
    valid =
      Enum.filter(rows, fn
        %{"path" => path, "kind" => kind} ->
          DesignAssets.path?(path) and kind in DesignAsset.kinds()

        _other ->
          false
      end)

    Map.put(data, "design_assets", valid)
  end

  defp keep_valid_assets(data), do: data

  # Field definitions skip their changeset on restore, so the shape is checked here.
  defp keep_valid_definitions(%{"field_definitions" => rows} = data) when is_list(rows) do
    valid =
      Enum.filter(rows, fn
        %{"object" => object, "key" => key, "type" => type, "label" => label} ->
          object in FieldDefinition.objects() and type in FieldDefinition.types() and
            is_binary(label) and is_binary(key) and String.match?(key, ~r/^[a-z][a-z0-9_]{0,62}$/)

        _other ->
          false
      end)

    Map.put(data, "field_definitions", valid)
  end

  defp keep_valid_definitions(data), do: data

  defp decode(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, _not_an_object} -> {:error, "That file is not a QuantumBilling backup."}
      {:error, _reason} -> {:error, "That file is not valid JSON."}
    end
  end

  defp check_version(%{"version" => version}) when version in @readable_versions, do: :ok

  defp check_version(%{"version" => other}),
    do:
      {:error,
       "Backup version #{other} cannot be restored by this release (expected #{@version})."}

  defp check_version(_data), do: {:error, "That file is not a QuantumBilling backup."}

  # A 2.0 file kept the e-way bill as columns on the invoice.
  defp upgrade(%{"version" => "2.0"} = data) do
    bills =
      data
      |> Map.get("invoices", [])
      |> Enum.filter(&issued?/1)
      |> Enum.with_index(1)
      |> Enum.map(&e_way_bill_from_invoice/1)

    data
    |> Map.put("e_way_bills", bills)
    |> Map.put("e_way_bill_part_b_updates", [])
    |> Map.put("version", "2.1")
    |> upgrade()
  end

  # A 2.1 file holds rupees where 3.0 holds paise.
  defp upgrade(%{"version" => "2.1"} = data) do
    data =
      Enum.reduce(@rupee_fields, data, fn {section, fields}, acc ->
        Map.update(acc, section, [], fn
          rows when is_list(rows) -> Enum.map(rows, &rupees_to_paise(&1, fields))
          other -> other
        end)
      end)

    data
    |> Map.update("organization", nil, &rupees_to_paise(&1, ~w(ewb_threshold_value)))
    |> Map.put("version", "3.0")
    |> upgrade()
  end

  # 3.0 had no custom fields; cast_row/3 fills `custom_fields` with %{}.
  defp upgrade(%{"version" => "3.0"} = data), do: data |> Map.put("version", "3.1") |> upgrade()

  # 3.1 had no VAT: every record is GST, and there are no tax rates.
  defp upgrade(%{"version" => "3.1"} = data) do
    @gst_defaults
    |> Enum.reduce(data, fn {section, defaults}, acc ->
      Map.update(acc, section, [], fn
        rows when is_list(rows) -> Enum.map(rows, &put_defaults(&1, defaults))
        other -> other
      end)
    end)
    |> Map.put("version", @version)
  end

  defp upgrade(data), do: data

  defp rupees_to_paise(row, fields) when is_map(row) do
    Enum.reduce(fields, row, fn field, acc ->
      case Map.fetch(acc, field) do
        {:ok, rupees} when is_integer(rupees) ->
          Map.put(acc, field, rupees * 100)

        {:ok, rupees} when is_binary(rupees) or is_float(rupees) ->
          Map.put(acc, field, paise(rupees))

        _absent_or_nil ->
          acc
      end
    end)
  end

  defp rupees_to_paise(other, _fields), do: other

  defp put_defaults(row, defaults) when is_map(row), do: Map.merge(defaults, row)
  defp put_defaults(other, _defaults), do: other

  # Leaves an unreadable value for cast_row/3 to reject by name.
  defp paise(rupees) do
    decimal = if is_float(rupees), do: Decimal.from_float(rupees), else: Decimal.parse(rupees)

    case decimal do
      %Decimal{} = decimal -> paise_of(decimal)
      {%Decimal{} = decimal, ""} -> paise_of(decimal)
      _not_a_number -> rupees
    end
  end

  defp paise_of(decimal) do
    decimal |> Decimal.mult(100) |> Decimal.round(0, :half_up) |> Decimal.to_integer()
  end

  defp issued?(%{"ewb_number" => number}) when is_binary(number), do: String.trim(number) != ""
  defp issued?(_invoice), do: false

  defp e_way_bill_from_invoice({invoice, id}) do
    ewb_date = invoice["ewb_date"] || invoice["invoice_date"]

    %{
      "id" => id,
      "invoice_id" => invoice["id"],
      "ewb_number" => invoice["ewb_number"],
      "ewb_date" => ewb_date,
      # Rule 138(10): assume the minimum one-day validity.
      "valid_until" => invoice["ewb_valid_until"] || day_after(ewb_date),
      "status" => if(invoice["status"] == "Cancelled", do: "Cancelled", else: "Active"),
      "distance_km" => invoice["distance_km"] || 0,
      "mode_of_transport" => invoice["mode_of_transport"] || "Road",
      "vehicle_number" => invoice["vehicle_number"],
      "transporter_id" => invoice["transporter_id"],
      "transporter_name" => invoice["transporter_name"]
    }
  end

  defp day_after(nil), do: nil

  defp day_after(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> date |> Date.add(1) |> NaiveDateTime.new!(~T[00:00:00]) |> to_string()
      {:error, _reason} -> nil
    end
  end

  defp day_after(_other), do: nil

  defp organization_row do
    case Repo.one(from o in Organization, order_by: [asc: o.id], limit: 1) do
      nil -> nil
      organization -> Map.take(organization, @organization_fields)
    end
  end

  # insert_all rather than changesets: re-validating old rows could reject them.
  defp insert_all!(_schema, nil, _fields), do: 0
  defp insert_all!(_schema, [], _fields), do: 0

  defp insert_all!(schema, rows, fields) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    has_timestamps? = :inserted_at in schema.__schema__(:fields)
    has_updated_at? = :updated_at in schema.__schema__(:fields)

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

  defp cast_row(row, schema, fields) when is_map(row) do
    cast =
      for field <- fields, into: %{} do
        value = Map.get(row, Atom.to_string(field), Map.get(row, field))
        value = if field == :custom_fields and is_nil(value), do: %{}, else: value

        case Ecto.Type.cast(stored_type(schema, field), value) do
          {:ok, cast} -> {field, cast}
          _error -> Repo.rollback("#{schema}.#{field} could not read #{inspect(value)}.")
        end
      end

    fill_portal_mode(schema, cast)
  end

  defp cast_row(other, schema, _fields) do
    Repo.rollback("#{schema} expected an object per row, got #{inspect(other)}.")
  end

  # Older backups without a portal mode: bills become demo, as in the migration that added it.
  defp fill_portal_mode(EWayBill, %{portal_mode: nil} = row), do: %{row | portal_mode: "demo"}

  defp fill_portal_mode(Invoice, %{irn_mode: nil, irn: irn} = row) when is_binary(irn) do
    mock? = String.starts_with?(row[:signed_invoice] || "", "MOCK_SIGNED_JWT_")
    %{row | irn_mode: if(mock?, do: "demo", else: "live")}
  end

  defp fill_portal_mode(_schema, row), do: row

  # The file holds paise; casting through Paise would read them as rupees.
  defp stored_type(schema, field) do
    case schema.__schema__(:type, field) do
      Paise -> :integer
      type -> type
    end
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

        case Ecto.Type.cast(stored_type(Organization, field), value) do
          {:ok, cast} -> {field, cast}
          _error -> Repo.rollback("organization.#{field} could not read #{inspect(value)}.")
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

  # Raw SQL skips Ecto's prefix, so the table is named with its schema.
  defp resync_sequence(table) do
    qualified = ~s("#{Repo.business_schema!()}".#{table})

    Repo.query!(
      """
      SELECT setval(
        pg_get_serial_sequence($1, 'id'),
        COALESCE((SELECT MAX(id) FROM #{qualified}), 0) + 1,
        false
      )
      """,
      [qualified]
    )
  end
end
