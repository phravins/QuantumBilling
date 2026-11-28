defmodule QuantumBilling.Audit.Catalog do
  @moduledoc """
  How each audit action reads to a person: its label, category, icon and tone.

  Covers the names written today and the older ones still in the trail. An
  unknown name falls back to a humanized form, so nothing shows blank.
  """

  # {action, label, category, icon, tone}
  @entries [
    # Invoices
    {"invoice_created", "Created invoice", "Invoices", "hero-document-plus", :create},
    {"create_invoice", "Created invoice", "Invoices", "hero-document-plus", :create},
    {"invoice_updated", "Edited invoice", "Invoices", "hero-pencil-square", :update},
    {"invoice_emailed", "Emailed invoice", "Invoices", "hero-envelope", :info},
    {"invoice_cancelled", "Cancelled invoice", "Invoices", "hero-no-symbol", :danger},
    {"bin_invoice", "Moved invoice to the Bin", "Invoices", "hero-trash", :danger},
    {"restore_invoice", "Restored invoice from the Bin", "Invoices", "hero-arrow-uturn-left",
     :update},
    {"purge_invoice", "Deleted invoice for good", "Invoices", "hero-x-circle", :danger},
    {"e_invoice_requested", "Requested e-invoice (IRN)", "Invoices", "hero-document-check",
     :info},
    {"e_invoice_generated", "Generated e-invoice (IRN)", "Invoices", "hero-document-check",
     :create},
    {"e_invoice_failed", "E-invoice failed", "Invoices", "hero-exclamation-triangle", :danger},
    {"generate_irn", "Generated e-invoice (IRN)", "Invoices", "hero-document-check", :create},
    # Quotations
    {"create_quotation", "Created quotation", "Quotations", "hero-document-plus", :create},
    {"update_quotation", "Edited quotation", "Quotations", "hero-pencil-square", :update},
    {"email_quotation", "Emailed quotation", "Quotations", "hero-envelope", :info},
    {"quotation_accepted", "Quotation accepted", "Quotations", "hero-check-circle", :create},
    {"quotation_declined", "Quotation declined", "Quotations", "hero-x-mark", :danger},
    {"convert_quotation", "Converted quotation to invoice", "Quotations",
     "hero-arrow-right-circle", :create},
    {"delete_quotation", "Moved quotation to the Bin", "Quotations", "hero-trash", :danger},
    {"restore_quotation", "Restored quotation from the Bin", "Quotations",
     "hero-arrow-uturn-left", :update},
    {"purge_quotation", "Deleted quotation for good", "Quotations", "hero-x-circle", :danger},
    # Clients
    {"client_created", "Added client", "Clients", "hero-user-plus", :create},
    {"client_updated", "Edited client", "Clients", "hero-pencil-square", :update},
    {"import_clients", "Imported clients", "Clients", "hero-arrow-up-tray", :create},
    {"bin_client", "Moved client to the Bin", "Clients", "hero-trash", :danger},
    {"restore_client", "Restored client from the Bin", "Clients", "hero-arrow-uturn-left",
     :update},
    {"purge_client", "Deleted client for good", "Clients", "hero-x-circle", :danger},
    # Credit and debit notes
    {"credit_note_created", "Issued credit note", "Credit notes", "hero-receipt-refund", :create},
    {"debit_note_created", "Issued debit note", "Credit notes", "hero-receipt-percent", :create},
    # E-way bills
    {"generate_e_way_bill", "Generated e-way bill", "E-way bills", "hero-truck", :create},
    {"update_e_way_bill_part_b", "Updated e-way bill vehicle", "E-way bills", "hero-truck",
     :update},
    {"extend_e_way_bill", "Extended e-way bill validity", "E-way bills", "hero-clock", :update},
    {"cancel_e_way_bill", "Cancelled e-way bill", "E-way bills", "hero-no-symbol", :danger},
    {"bin_e_way_bill", "Moved e-way bill to the Bin", "E-way bills", "hero-trash", :danger},
    {"restore_e_way_bill", "Restored e-way bill from the Bin", "E-way bills",
     "hero-arrow-uturn-left", :update},
    {"purge_e_way_bill", "Deleted e-way bill for good", "E-way bills", "hero-x-circle", :danger},
    # Payments
    {"generate_payment_link", "Created payment link", "Payments", "hero-link", :create},
    {"payment_link_cancelled", "Cancelled payment link", "Payments", "hero-link-slash", :danger},
    {"payment_received", "Payment received", "Payments", "hero-banknotes", :create},
    {"payment_rejected", "Payment rejected", "Payments", "hero-exclamation-triangle", :danger},
    # Recurring
    {"recurring_profile_created", "Created recurring profile", "Recurring", "hero-arrow-path",
     :create},
    {"recurring_profile_updated", "Edited recurring profile", "Recurring", "hero-pencil-square",
     :update},
    {"recurring_profile_paused", "Paused recurring profile", "Recurring", "hero-pause-circle",
     :info},
    {"recurring_profile_resumed", "Resumed recurring profile", "Recurring", "hero-play-circle",
     :info},
    {"bin_recurring_profile", "Moved recurring profile to the Bin", "Recurring", "hero-trash",
     :danger},
    {"restore_recurring_profile", "Restored recurring profile from the Bin", "Recurring",
     "hero-arrow-uturn-left", :update},
    {"purge_recurring_profile", "Deleted recurring profile for good", "Recurring",
     "hero-x-circle", :danger},
    # Templates
    {"invoice_template_created", "Created invoice template", "Templates", "hero-swatch", :create},
    {"invoice_template_updated", "Edited invoice template", "Templates", "hero-pencil-square",
     :update},
    {"invoice_template_duplicated", "Duplicated invoice template", "Templates",
     "hero-document-duplicate", :create},
    {"invoice_template_imported", "Imported invoice template", "Templates", "hero-arrow-up-tray",
     :create},
    {"invoice_template_set_default", "Made template the default", "Templates", "hero-star",
     :update},
    {"bin_invoice_template", "Moved invoice template to the Bin", "Templates", "hero-trash",
     :danger},
    {"restore_invoice_template", "Restored invoice template from the Bin", "Templates",
     "hero-arrow-uturn-left", :update},
    {"purge_invoice_template", "Deleted invoice template for good", "Templates", "hero-x-circle",
     :danger},
    # Settings
    {"settings_updated", "Changed settings", "Settings", "hero-cog-6-tooth", :update},
    {"tax_rate_created", "Added tax rate", "Settings", "hero-receipt-percent", :create},
    {"tax_rate_updated", "Edited tax rate", "Settings", "hero-pencil-square", :update},
    {"tax_rate_archived", "Archived tax rate", "Settings", "hero-archive-box", :danger},
    {"tax_rate_restored", "Restored tax rate", "Settings", "hero-arrow-uturn-left", :update},
    {"tax_rate_default_set", "Made tax rate the default", "Settings", "hero-star", :update},
    {"tax_rates_preset_added", "Added preset tax rates", "Settings", "hero-receipt-percent",
     :create},
    {"custom_field_created", "Added custom field", "Settings", "hero-table-cells", :create},
    {"custom_field_updated", "Edited custom field", "Settings", "hero-pencil-square", :update},
    {"custom_field_archived", "Archived custom field", "Settings", "hero-archive-box", :danger},
    {"custom_field_restored", "Restored custom field", "Settings", "hero-arrow-uturn-left",
     :update},
    {"custom_field_deleted", "Deleted custom field", "Settings", "hero-x-circle", :danger},
    # Compliance
    {"create_compliance_task", "Added compliance task", "Compliance",
     "hero-clipboard-document-check", :create},
    {"update_compliance_task", "Edited compliance task", "Compliance", "hero-pencil-square",
     :update},
    {"complete_compliance_task", "Completed compliance task", "Compliance", "hero-check-circle",
     :update},
    {"reopen_compliance_task", "Reopened compliance task", "Compliance", "hero-arrow-uturn-left",
     :update},
    {"delete_compliance_task", "Deleted compliance task", "Compliance", "hero-x-circle", :danger},
    {"mark_compliance_filed", "Marked return filed", "Compliance", "hero-check-badge", :create},
    {"undo_compliance_filed", "Undid return filing", "Compliance", "hero-arrow-uturn-left",
     :danger},
    # Team
    {"member_invited", "Invited member", "Team", "hero-user-plus", :create},
    {"invitation_revoked", "Revoked invitation", "Team", "hero-user-minus", :danger},
    {"member_role_changed", "Changed member's role", "Team", "hero-shield-check", :update},
    {"member_removed", "Removed member", "Team", "hero-user-minus", :danger},
    # API, webhooks and integrations
    {"api_key_created", "Created API key", "Integrations", "hero-key", :create},
    {"api_key_revoked", "Revoked API key", "Integrations", "hero-key", :danger},
    {"webhook_endpoint_created", "Added webhook endpoint", "Integrations", "hero-signal",
     :create},
    {"webhook_endpoint_updated", "Edited webhook endpoint", "Integrations", "hero-signal",
     :update},
    {"webhook_endpoint_deleted", "Deleted webhook endpoint", "Integrations", "hero-signal",
     :danger},
    {"webhook_secret_rotated", "Rotated webhook secret", "Integrations", "hero-arrow-path",
     :update},
    {"calendar_connected", "Connected calendar", "Integrations", "hero-calendar", :create},
    {"calendar_disconnected", "Disconnected calendar", "Integrations", "hero-calendar", :danger},
    # Data
    {"backup_downloaded", "Downloaded backup", "Data", "hero-arrow-down-tray", :info},
    {"backup_restored", "Restored backup", "Data", "hero-arrow-path", :danger}
  ]

  @by_action Map.new(@entries, fn {action, label, category, icon, tone} ->
               {action, %{label: label, category: category, icon: icon, tone: tone}}
             end)

  @categories @entries |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

  @actions_by_category Enum.group_by(@entries, &elem(&1, 2), &elem(&1, 0))

  @doc "Every category, in display order."
  def categories, do: @categories

  @doc "The actions in `category`, or `[]` for an unknown one."
  def actions(category), do: Map.get(@actions_by_category, category, [])

  @doc "A sentence-case label for `action`."
  def label(action) do
    case Map.fetch(@by_action, to_string(action)) do
      {:ok, entry} -> entry.label
      :error -> humanize(action)
    end
  end

  @doc "The category `action` belongs to, or \"Other\"."
  def category(action), do: get(action, :category, "Other")

  @doc "A `hero-*` icon for `action`."
  def icon(action), do: get(action, :icon, "hero-bolt")

  @doc "`:create`, `:update`, `:danger` or `:info`, for colouring."
  def tone(action), do: get(action, :tone, :info)

  @doc """
  Where the record an entry is about can be seen, or `nil`.

  Records with no page of their own link to the list or settings page that
  shows them. The caller checks a linked record still exists.
  """
  def record_path(resource_type, resource_id, details \\ %{})

  def record_path("Invoice", id, _details) when is_binary(id), do: "/invoices/#{id}"
  def record_path("Quotation", id, _details) when is_binary(id), do: "/quotations/#{id}"
  def record_path("Client", id, _details) when is_binary(id), do: "/clients/#{id}"

  def record_path("InvoiceTemplate", id, _details) when is_binary(id),
    do: "/invoice-templates/#{id}"

  def record_path("CreditNote", _id, %{"invoice_id" => invoice_id})
      when not is_nil(invoice_id),
      do: "/invoices/#{invoice_id}"

  def record_path("EWayBill", _id, _details), do: "/e-way-bills"
  def record_path("RecurringProfile", _id, _details), do: "/recurring"
  def record_path("Settings", id, _details) when is_binary(id), do: "/settings/#{id}"
  def record_path("TaxRate", _id, _details), do: "/settings/tax"
  def record_path("FieldDefinition", _id, _details), do: "/settings/data-model"
  def record_path(type, _id, _details) when type in ["User", "Invitation"], do: "/settings/team"
  def record_path("ApiKey", _id, _details), do: "/settings/api-keys"
  def record_path("WebhookEndpoint", _id, _details), do: "/settings/webhooks"
  def record_path("CalendarConnection", _id, _details), do: "/settings/integrations"
  def record_path("Backup", _id, _details), do: "/settings/backup"

  def record_path(type, _id, _details) when type in ["ComplianceTask", "ComplianceFiling"],
    do: "/compliance"

  def record_path(_type, _id, _details), do: nil

  @doc "Whether `resource_type` has a page per record, which may since have been deleted."
  def own_page?(resource_type),
    do: resource_type in ["Invoice", "Quotation", "Client", "InvoiceTemplate"]

  @doc "Whether the action moved its record to the Bin or deleted it."
  def removal?(action) do
    action = to_string(action)

    String.starts_with?(action, ["bin_", "purge_", "delete_"]) or
      String.ends_with?(action, "_deleted")
  end

  @doc "A field name as a person would say it: `\"grand_total\"` → `\"Grand total\"`."
  def field_label(field) do
    field = to_string(field)

    Map.get_lazy(field_names(), field, fn -> humanize(field) end)
  end

  @doc "Whether a field holds money in paise, to show it in rupees."
  def money_field?(field) do
    field = to_string(field)

    field in ~w(subtotal grand_total amount amount_paid taxable_value tax_total discount_total
                round_off total_value accepted_total) or
      String.ends_with?(field, "_amount")
  end

  defp field_names do
    %{
      "gstin" => "GSTIN",
      "pan" => "PAN",
      "irn" => "IRN",
      "hsn_code" => "HSN code",
      "sac_code" => "SAC code",
      "cgst_amount" => "CGST",
      "sgst_amount" => "SGST",
      "igst_amount" => "IGST",
      "cess_amount" => "Cess",
      "accepted_total" => "Accepted total",
      "smtp_password" => "SMTP password",
      "smtp_host" => "SMTP host",
      "smtp_port" => "SMTP port",
      "smtp_username" => "SMTP username",
      "razorpay_key_id" => "Razorpay key ID",
      "razorpay_key_secret" => "Razorpay key secret",
      "razorpay_webhook_secret" => "Razorpay webhook secret",
      "irp_username" => "IRP username",
      "irp_password" => "IRP password",
      "doc_logo_path" => "Logo",
      "layout_xml" => "Layout",
      "items" => "Line items",
      "upi_id" => "UPI ID",
      "ifsc_code" => "IFSC code"
    }
  end

  defp get(action, key, default) do
    case Map.fetch(@by_action, to_string(action)) do
      {:ok, entry} -> Map.fetch!(entry, key)
      :error -> default
    end
  end

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.trim()
    |> String.capitalize()
  end
end
