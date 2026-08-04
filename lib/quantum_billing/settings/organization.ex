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

  # Three takes on the same document rather than a free canvas: every one of
  # these still has to satisfy the same GST disclosure rules, so what varies is
  # emphasis and density, not which facts appear.
  @doc_templates ["Classic", "Modern", "Compact"]

  schema "organization_settings" do
    field :company_name, :string
    field :trade_name, :string
    field :address, :string
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

    # How the invoice document looks. Presentation, read live at render time —
    # unlike the figures and party details, which each invoice snapshots.
    field :doc_template, :string, default: "Classic"
    field :doc_accent_color, :string, default: "#18181b"
    field :doc_logo_path, :string
    field :doc_heading, :string
    field :doc_footer_text, :string
    field :doc_show_hsn, :boolean, default: true
    field :doc_show_unit, :boolean, default: true
    field :doc_show_tax_rate, :boolean, default: true
    field :doc_show_remarks, :boolean, default: true
    field :doc_show_amount_words, :boolean, default: true
    field :doc_show_cess, :boolean, default: false

    field :singleton, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @general ~w(company_name trade_name address phone email gstin pan state
              currency financial_year timezone date_format)a

  @invoice ~w(invoice_prefix invoice_next_number invoice_number_padding
              invoice_due_days invoice_terms)a

  @e_way_bill ~w(ewb_transport_mode ewb_transporter_id ewb_threshold_value
                 ewb_auto_generate)a

  @tax ~w(default_gst_rate cess_enabled composition_scheme tds_enabled)a

  @notifications ~w(notify_invoice_created notify_ewb_generated
                    notify_filing_reminders reminder_lead_days)a

  @preferences ~w(language rows_per_page)a

  # `doc_logo_path` is cast here but never typed into: the panel writes it from
  # the stored upload's path, not from a text box.
  @customization ~w(doc_template doc_accent_color doc_logo_path doc_heading
                    doc_footer_text doc_show_hsn doc_show_unit doc_show_tax_rate
                    doc_show_remarks doc_show_amount_words doc_show_cess)a

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

  def changeset(organization, attrs, :customization) do
    organization
    |> cast(attrs, @customization)
    |> validate_inclusion(:doc_template, @doc_templates)
    # The colour is written straight into a `style` attribute on the document,
    # so it is pinned to six hex digits rather than accepting any CSS colour
    # string. A named colour or a `var(--x)` would be harmless; `red; content:`
    # would not.
    |> validate_format(:doc_accent_color, ~r/^#[0-9A-Fa-f]{6}$/,
      message: "must be a hex colour like #1D4ED8"
    )
    |> validate_length(:doc_heading, max: 60)
    |> validate_length(:doc_footer_text, max: 300)
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

  def gst_rates, do: @gst_rates
  def currencies, do: @currencies
  def date_formats, do: @date_formats
  def timezones, do: @timezones
  def languages, do: @languages
  def rows_per_page_options, do: @rows_per_page
  def doc_templates, do: @doc_templates
end
