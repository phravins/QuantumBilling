defmodule QuantumBilling.Settings.Organization do
  @moduledoc """
  The organisation's settings — one row holding the whole configuration.

  There is a changeset per section rather than one for the schema, because the
  Settings page saves a single panel at a time: a `general_changeset/2` must not
  reject a save because the invoice terms are blank on a different panel.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.GST

  # The statutory GST slabs.
  @gst_rates [0, 5, 12, 18, 28]

  @currencies ["INR (₹) - Indian Rupee"]

  @date_formats [
    "DD MMM YYYY",
    "DD/MM/YYYY",
    "MM/DD/YYYY",
    "YYYY-MM-DD"
  ]

  @timezones ["Asia/Kolkata"]

  @languages ["en"]

  @rows_per_page [10, 25, 50, 100]

  schema "organization_settings" do
    field :company_name, :string
    field :trade_name, :string
    field :address, :string
    # Structured beside the address blob rather than parsed out of it: the GST
    # e-invoice schema wants a location and a PIN as their own fields, and
    # guessing at where they sit inside a free-text address gets it wrong for
    # anyone who formats theirs unusually.
    field :city, :string
    field :pincode, :string
    field :phone, :string
    field :email, :string

    field :gstin, :string
    field :pan, :string
    field :state, :string

    field :currency, :string, default: "INR (₹) - Indian Rupee"
    field :financial_year, :string
    field :timezone, :string, default: "Asia/Kolkata"
    field :date_format, :string, default: "DD MMM YYYY"

    field :invoice_prefix, :string, default: "INV"
    field :invoice_next_number, :integer, default: 1
    field :invoice_number_padding, :integer, default: 4
    field :invoice_due_days, :integer, default: 30
    field :invoice_terms, :string

    field :ewb_transport_mode, :string, default: "Road"
    field :ewb_transporter_id, :string
    field :ewb_threshold_value, :integer, default: 50_000
    field :ewb_auto_generate, :boolean, default: false

    field :default_gst_rate, :integer, default: 18
    field :cess_enabled, :boolean, default: false
    field :composition_scheme, :boolean, default: false
    field :tds_enabled, :boolean, default: false

    field :notify_invoice_created, :boolean, default: true
    field :notify_ewb_generated, :boolean, default: true
    field :notify_filing_reminders, :boolean, default: true
    field :reminder_lead_days, :integer, default: 7

    field :language, :string, default: "en"
    field :rows_per_page, :integer, default: 10

    # Custom SMTP Settings
    field :smtp_host, :string
    field :smtp_port, :integer, default: 587
    field :smtp_username, :string
    field :smtp_password, :string
    field :smtp_ssl, :boolean, default: false
    field :smtp_from_email, :string
    field :smtp_from_name, :string

    # API & Webhook Integrations
    field :razorpay_key_id, :string
    field :razorpay_key_secret, :string
    field :irp_username, :string
    field :irp_password, :string
    field :irp_client_id, :string
    field :webhook_url, :string
    field :webhook_secret, :string

    # Security Settings
    field :allowed_ips, :string
    field :session_timeout_minutes, :integer, default: 60
    field :enforce_2fa, :boolean, default: false
    field :audit_retention_days, :integer, default: 90

    field :doc_logo_path, :string

    field :singleton, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @general ~w(company_name trade_name address city pincode phone email gstin pan
              state currency financial_year timezone date_format)a

  @invoice ~w(invoice_prefix invoice_next_number invoice_number_padding
              invoice_due_days invoice_terms)a

  @e_way_bill ~w(ewb_transport_mode ewb_transporter_id ewb_threshold_value
                 ewb_auto_generate)a

  @tax ~w(default_gst_rate cess_enabled composition_scheme tds_enabled)a

  @notifications ~w(notify_invoice_created notify_ewb_generated
                    notify_filing_reminders reminder_lead_days)a

  @preferences ~w(language rows_per_page)a

  @customization ~w(doc_logo_path)a

  @smtp ~w(smtp_host smtp_port smtp_username smtp_password smtp_ssl smtp_from_email smtp_from_name)a

  @integrations ~w(razorpay_key_id razorpay_key_secret irp_username irp_password irp_client_id webhook_url webhook_secret)a

  @security ~w(allowed_ips session_timeout_minutes enforce_2fa audit_retention_days)a

  @doc """
  Builds the changeset for one section.

  Dispatching by section keeps a panel's save from being blocked by a field it
  does not show.
  """
  def changeset(organization, attrs, section)

  def changeset(organization, attrs, :general) do
    organization
    |> cast(attrs, @general)
    |> validate_required([:company_name])
    |> validate_length(:company_name, max: 160)
    # Optional, because it is new and nobody has been asked for it — but an
    # Indian PIN is exactly six digits, so a wrong one is caught here rather
    # than by the e-invoice export weeks later.
    |> validate_format(:pincode, ~r/^\d{6}$/, message: "must be six digits")
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> GST.validate_gstin(:gstin)
    |> GST.validate_pan(:pan)
    |> GST.validate_gstin_matches_pan(:gstin, :pan)
    |> validate_inclusion(:state, EWayBillForm.states())
    |> validate_inclusion(:currency, @currencies)
    |> validate_inclusion(:date_format, @date_formats)
    |> validate_inclusion(:timezone, @timezones)
  end

  def changeset(organization, attrs, :invoice) do
    organization
    |> cast(attrs, @invoice)
    |> validate_required([:invoice_prefix, :invoice_next_number])
    |> validate_format(:invoice_prefix, ~r/^[A-Za-z0-9\-\/]+$/,
      message: "may only contain letters, numbers, dashes and slashes"
    )
    |> validate_length(:invoice_prefix, max: 12)
    |> validate_number(:invoice_next_number, greater_than: 0)
    |> validate_number(:invoice_number_padding, greater_than_or_equal_to: 0, less_than: 12)
    |> validate_number(:invoice_due_days, greater_than_or_equal_to: 0, less_than_or_equal_to: 365)
  end

  def changeset(organization, attrs, :e_way_bill) do
    organization
    |> cast(attrs, @e_way_bill)
    |> validate_inclusion(:ewb_transport_mode, EWayBillForm.transport_modes())
    |> maybe_validate_transporter_id()
    |> validate_number(:ewb_threshold_value, greater_than_or_equal_to: 0)
  end

  def changeset(organization, attrs, :tax) do
    organization
    |> cast(attrs, @tax)
    |> validate_inclusion(:default_gst_rate, @gst_rates,
      message: "must be one of the GST slabs: #{Enum.join(@gst_rates, ", ")}"
    )
  end

  def changeset(organization, attrs, :notifications) do
    organization
    |> cast(attrs, @notifications)
    |> validate_number(:reminder_lead_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 60
    )
  end

  def changeset(organization, attrs, :preferences) do
    organization
    |> cast(attrs, @preferences)
    |> validate_inclusion(:language, @languages)
    |> validate_inclusion(:rows_per_page, @rows_per_page)
  end

  # The accent's hex validation moved to `InvoiceTemplate` along with the column,
  # for the same reason it existed here: it is written straight into a `style`
  # attribute on the document, so it is pinned to six hex digits rather than
  # accepting any CSS colour string.
  def changeset(organization, attrs, :customization) do
    cast(organization, attrs, @customization)
  end

  def changeset(organization, attrs, :smtp) do
    organization
    |> cast(attrs, @smtp)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65536)
  end

  def changeset(organization, attrs, :integrations) do
    cast(organization, attrs, @integrations)
  end

  def changeset(organization, attrs, :security) do
    organization
    |> cast(attrs, @security)
    |> validate_number(:session_timeout_minutes, greater_than: 0)
    |> validate_number(:audit_retention_days, greater_than: 0)
  end

  # The transporter ID is optional, but must be a GSTIN when supplied.
  defp maybe_validate_transporter_id(changeset) do
    case get_field(changeset, :ewb_transporter_id) do
      blank when blank in [nil, ""] -> changeset
      _present -> GST.validate_gstin(changeset, :ewb_transporter_id)
    end
  end

  @doc "Fields belonging to `section`, for building the form."
  def fields(:general), do: @general
  def fields(:invoice), do: @invoice
  def fields(:e_way_bill), do: @e_way_bill
  def fields(:tax), do: @tax
  def fields(:notifications), do: @notifications
  def fields(:preferences), do: @preferences
  def fields(:customization), do: @customization
  def fields(:smtp), do: @smtp
  def fields(:integrations), do: @integrations
  def fields(:security), do: @security

  def gst_rates, do: @gst_rates
  def currencies, do: @currencies
  def date_formats, do: @date_formats
  def timezones, do: @timezones
  def languages, do: @languages
  def rows_per_page_options, do: @rows_per_page
end
