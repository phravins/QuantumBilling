defmodule QuantumBilling.Settings.Organization do
  @moduledoc """
  The organisation's settings, one row. Each Settings panel has its own
  changeset, so saving one panel isn't blocked by another's fields.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Encrypted
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.GST
  alias QuantumBilling.Money.Paise
  alias QuantumBilling.Tax

  @gst_rates [0, 5, 12, 18, 28]

  @currencies QuantumBilling.Currency.labels()

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
    # Kept apart from the address: the e-invoice schema needs city and PIN as fields.
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
    field :ewb_threshold_value, Paise, default: 5_000_000
    field :ewb_auto_generate, :boolean, default: false

    field :default_gst_rate, :integer, default: 18
    field :cess_enabled, :boolean, default: false
    field :composition_scheme, :boolean, default: false
    field :tds_enabled, :boolean, default: false

    # "gst" or "vat" (see QuantumBilling.Tax). VAT businesses keep their rates in tax_rates.
    field :tax_regime, :string, default: "gst"
    field :vat_number, :string
    field :vat_country, :string
    field :prices_include_tax, :boolean, default: false
    # nil is the regime's default: whole units for GST, exact for VAT.
    field :round_to_whole_units, :boolean

    field :notify_invoice_created, :boolean, default: true
    field :notify_ewb_generated, :boolean, default: true
    field :notify_filing_reminders, :boolean, default: true
    field :reminder_lead_days, :integer, default: 7

    field :language, :string, default: "en"
    field :rows_per_page, :integer, default: 10

    # SMTP. The password is encrypted at rest (see Encrypted.Secret).
    field :smtp_host, :string
    field :smtp_port, :integer, default: 587
    field :smtp_username, :string
    field :smtp_password, Encrypted.Secret, redact: true
    field :smtp_ssl, :boolean, default: false
    field :smtp_from_email, :string
    field :smtp_from_name, :string

    # UPI: printed on the invoice, so not a secret.
    field :upi_vpa, :string
    field :upi_payee_name, :string

    # Integrations. The credentials among them are encrypted.
    field :razorpay_key_id, :string
    field :razorpay_key_secret, Encrypted.Secret, redact: true
    field :irp_username, :string
    field :irp_password, Encrypted.Secret, redact: true
    field :irp_client_id, :string
    field :webhook_url, :string
    field :webhook_secret, Encrypted.Secret, redact: true

    # Security: the sign-in rules belong to `InstallationSettings` and are virtual
    # here so one form edits them beside this business's audit retention.
    field :allowed_ips, :string, virtual: true
    field :session_timeout_minutes, :integer, default: 60, virtual: true
    field :enforce_2fa, :boolean, default: false, virtual: true
    field :audit_retention_days, :integer, default: 90

    field :doc_logo_path, :string

    # Printed by the Payment details block on an invoice design.
    field :bank_account_name, :string
    field :bank_name, :string
    field :bank_account_number, :string
    field :bank_ifsc, :string
    field :bank_branch, :string

    field :singleton, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @general ~w(company_name trade_name address city pincode phone email gstin pan
              state currency financial_year timezone date_format)a

  @invoice ~w(invoice_prefix invoice_next_number invoice_number_padding
              invoice_due_days invoice_terms)a

  @bank ~w(bank_account_name bank_name bank_account_number bank_ifsc bank_branch)a

  @e_way_bill ~w(ewb_transport_mode ewb_transporter_id ewb_threshold_value
                 ewb_auto_generate)a

  @tax ~w(default_gst_rate cess_enabled composition_scheme tds_enabled tax_regime vat_number
          vat_country prices_include_tax round_to_whole_units)a

  @notifications ~w(notify_invoice_created notify_ewb_generated
                    notify_filing_reminders reminder_lead_days)a

  @preferences ~w(language rows_per_page)a

  @customization ~w(doc_logo_path)a

  @smtp ~w(smtp_host smtp_port smtp_username smtp_password smtp_ssl smtp_from_email smtp_from_name)a

  # `webhook_url` and `webhook_secret` are legacy; webhooks have their own endpoints now.
  @integrations ~w(upi_vpa upi_payee_name razorpay_key_id razorpay_key_secret irp_username
                   irp_password irp_client_id)a

  @security ~w(allowed_ips session_timeout_minutes enforce_2fa audit_retention_days)a

  @doc "The changeset for one Settings section."
  def changeset(organization, attrs, section)

  def changeset(organization, attrs, :general) do
    organization
    |> cast(attrs, @general)
    |> validate_required([:company_name])
    |> validate_length(:company_name, max: 160)
    # An Indian PIN is exactly six digits.
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
    |> cast(attrs, @invoice ++ @bank)
    |> trim(@bank)
    |> update_change(:bank_ifsc, &String.upcase/1)
    |> validate_format(:bank_ifsc, ~r/^[A-Z]{4}0[A-Z0-9]{6}$/,
      message: "must be 11 characters like HDFC0001234"
    )
    |> update_change(:bank_account_number, &String.replace(&1, " ", ""))
    |> validate_format(:bank_account_number, ~r/^[0-9]{6,20}$/, message: "must be 6 to 20 digits")
    |> validate_length(:bank_account_name, max: 120)
    |> validate_length(:bank_name, max: 120)
    |> validate_length(:bank_branch, max: 120)
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
    |> validate_required([:tax_regime])
    |> validate_inclusion(:tax_regime, Tax.regime_codes())
    |> validate_vat()
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
    cast(organization, attrs, @customization)
  end

  def changeset(organization, attrs, :smtp) do
    organization
    |> cast(attrs, @smtp)
    |> keep_stored_secrets()
    |> trim(@smtp)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65536)
    |> validate_format(:smtp_from_email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_format(:smtp_host, ~r|^[^\s/:]+$|,
      message: "must be a hostname only, without https:// or a port"
    )
    |> validate_smtp_credentials_paired()
  end

  def changeset(organization, attrs, :integrations) do
    organization
    |> cast(attrs, @integrations)
    |> keep_stored_secrets()
    |> trim(@integrations)
    |> validate_upi_vpa()
  end

  def changeset(organization, attrs, :security) do
    organization
    |> cast(attrs, @security)
    |> validate_number(:session_timeout_minutes, greater_than: 0, less_than_or_equal_to: 10_080)
    |> validate_number(:audit_retention_days, greater_than: 0, less_than_or_equal_to: 3_650)
    |> validate_allowed_ips()
  end

  # Credentials for other systems: never rendered back into the settings page.
  @write_only ~w(smtp_password razorpay_key_secret irp_password webhook_secret)a

  @doc """
  The organisation with stored secrets blanked for display. A blank secret on save keeps the stored one.
  """
  def scrub_secrets(%__MODULE__{} = organization) do
    Enum.reduce(@write_only, organization, &Map.put(&2, &1, nil))
  end

  # A blank secret field means "unchanged"; the form never shows the stored value.
  defp keep_stored_secrets(changeset) do
    Enum.reduce(@write_only, changeset, fn field, acc ->
      # fetch_change/2 tells a cleared field (nil change) from an untouched one.
      case fetch_change(acc, field) do
        {:ok, nil} -> delete_change(acc, field)
        {:ok, value} when is_binary(value) -> maybe_drop_blank(acc, field, value)
        _no_change -> acc
      end
    end)
  end

  defp maybe_drop_blank(changeset, field, value) do
    if String.trim(value) == "", do: delete_change(changeset, field), else: changeset
  end

  defp trim(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_change(acc, field) do
        value when is_binary(value) -> put_change(acc, field, String.trim(value))
        _other -> acc
      end
    end)
  end

  defp validate_smtp_credentials_paired(changeset) do
    username = get_field(changeset, :smtp_username)
    password = get_field(changeset, :smtp_password)

    if present?(username) and not present?(password) do
      add_error(changeset, :smtp_password, "is required when a username is set")
    else
      changeset
    end
  end

  # The common mistake is entering an email address.
  defp validate_upi_vpa(changeset) do
    case get_field(changeset, :upi_vpa) do
      blank when blank in [nil, ""] ->
        changeset

      vpa ->
        if Regex.match?(~r/^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$/, String.trim(vpa)) do
          changeset
        else
          add_error(
            changeset,
            :upi_vpa,
            "must be a UPI ID like yourbusiness@okhdfcbank, not an email address"
          )
        end
    end
  end

  @doc false
  def validate_allowed_ips(changeset) do
    case get_field(changeset, :allowed_ips) do
      blank when blank in [nil, ""] ->
        changeset

      list ->
        invalid =
          list
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reject(&valid_ip_entry?/1)

        case invalid do
          [] -> changeset
          bad -> add_error(changeset, :allowed_ips, "not an IP or CIDR: #{Enum.join(bad, ", ")}")
        end
    end
  end

  defp valid_ip_entry?(entry) do
    case String.split(entry, "/") do
      [address] ->
        match?({:ok, _}, :inet.parse_address(to_charlist(address)))

      [address, prefix] ->
        with {:ok, parsed} <- :inet.parse_address(to_charlist(address)),
             {length, ""} <- Integer.parse(prefix) do
          length >= 0 and length <= if(tuple_size(parsed) == 4, do: 32, else: 128)
        else
          _invalid -> false
        end

      _too_many_slashes ->
        false
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # A VAT business needs its country; its VAT number is optional but must fit it.
  defp validate_vat(changeset) do
    if get_field(changeset, :tax_regime) == "vat" do
      country = get_field(changeset, :vat_country)

      changeset
      |> validate_required([:vat_country], message: "choose the country you charge VAT in")
      |> validate_inclusion(:vat_country, Tax.country_codes())
      |> Tax.validate_tax_number(:vat_number, country)
    else
      changeset
    end
  end

  defp maybe_validate_transporter_id(changeset) do
    case get_field(changeset, :ewb_transporter_id) do
      blank when blank in [nil, ""] -> changeset
      _present -> GST.validate_gstin(changeset, :ewb_transporter_id)
    end
  end

  def gst_rates, do: @gst_rates
  def currencies, do: @currencies

  @doc "The ISO code of the business currency, e.g. `\"INR\"`."
  def currency_code(%__MODULE__{currency: label}),
    do: QuantumBilling.Currency.code_from_label(label)

  def currency_code(_organization), do: QuantumBilling.Currency.default()

  @doc "The business's tax regime, `\"gst\"` or `\"vat\"`."
  def tax_regime(%__MODULE__{tax_regime: "vat"}), do: "vat"
  def tax_regime(_organization), do: "gst"

  def vat?(organization), do: tax_regime(organization) == "vat"

  @doc "Whether invoice totals round to whole units: the setting, else yes for GST and no for VAT."
  def round_to_whole_units?(%__MODULE__{round_to_whole_units: round?}) when is_boolean(round?),
    do: round?

  def round_to_whole_units?(organization), do: not vat?(organization)

  @doc "The tax fields a new invoice snapshots from the business."
  def invoice_tax_snapshot(organization) do
    vat? = vat?(organization)

    %{
      tax_regime: tax_regime(organization),
      prices_include_tax: vat? and organization.prices_include_tax == true,
      round_to_whole_units: round_to_whole_units?(organization),
      company_tax_number: if(vat?, do: organization.vat_number)
    }
  end

  def date_formats, do: @date_formats
  def timezones, do: @timezones
  def languages, do: @languages
  def rows_per_page_options, do: @rows_per_page
end
