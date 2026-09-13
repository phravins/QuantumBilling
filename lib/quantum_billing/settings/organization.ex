defmodule QuantumBilling.Settings.Organization do
  @moduledoc """
  The organisation's settings — one row holding the whole configuration.

  There is a changeset per section rather than one for the schema, because the
  Settings page saves a single panel at a time: a `general_changeset/2` must not
  reject a save because the invoice terms are blank on a different panel.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.Encrypted
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

    # Custom SMTP Settings. The password is encrypted at rest — see
    # `QuantumBilling.Encrypted.Secret` — because a mail relay has to be given
    # it verbatim, so it cannot be hashed like a login password.
    field :smtp_host, :string
    field :smtp_port, :integer, default: 587
    field :smtp_username, :string
    field :smtp_password, Encrypted.Secret
    field :smtp_ssl, :boolean, default: false
    field :smtp_from_email, :string
    field :smtp_from_name, :string

    # API & Webhook Integrations. Same treatment for the three credentials
    # among them; the ids and the URL are configuration and stay readable.
    field :razorpay_key_id, :string
    field :razorpay_key_secret, Encrypted.Secret
    field :irp_username, :string
    field :irp_password, Encrypted.Secret
    field :irp_client_id, :string
    field :webhook_url, :string
    field :webhook_secret, Encrypted.Secret

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
    |> keep_stored_secrets()
    |> trim(@smtp)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65536)
    |> validate_format(:smtp_from_email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    # A relay address with a scheme or a path in it is a copied-and-pasted URL,
    # and gen_smtp would spend its connection timeout finding that out.
    |> validate_format(:smtp_host, ~r|^[^\s/:]+$|,
      message: "must be a hostname only, without https:// or a port"
    )
    # Anonymous relays exist, but a username with no password is always a
    # half-filled form, and it fails at the relay with an error nobody can read.
    |> validate_smtp_credentials_paired()
  end

  def changeset(organization, attrs, :integrations) do
    organization
    |> cast(attrs, @integrations)
    |> keep_stored_secrets()
    |> trim(@integrations)
    |> validate_webhook_url()
  end

  def changeset(organization, attrs, :security) do
    organization
    |> cast(attrs, @security)
    |> validate_number(:session_timeout_minutes, greater_than: 0, less_than_or_equal_to: 10_080)
    |> validate_number(:audit_retention_days, greater_than: 0, less_than_or_equal_to: 3_650)
    |> validate_allowed_ips()
  end

  @write_only ~w(smtp_password razorpay_key_secret irp_password webhook_secret)a

  @doc """
  The fields that are never sent back to the browser.

  These are credentials for other systems. The settings form is write-only for
  them: a `password` input still renders its value into the HTML, so showing
  the stored password would publish it in the page source of every settings
  load — to a shoulder, a screen share, a cached page, a browser extension.
  """
  def secret_fields, do: @write_only

  @doc """
  The organisation with its stored credentials blanked out, for rendering.

  Saving is unaffected: a blank secret in a submitted form means "leave it
  alone" (see `keep_stored_secrets/1`), so a panel can be saved without
  retyping credentials that were never displayed.
  """
  def scrub_secrets(%__MODULE__{} = organization) do
    Enum.reduce(@write_only, organization, &Map.put(&2, &1, nil))
  end

  @doc "Whether `field` currently holds a stored credential."
  def secret_present?(%__MODULE__{} = organization, field) when field in @write_only do
    case Map.get(organization, field) do
      value when is_binary(value) -> String.trim(value) != ""
      _absent -> false
    end
  end

  # An empty secret box means "unchanged", because the form never showed what
  # was there. Clearing a credential is done by removing the host or the key it
  # belongs to, which is visible in the form and therefore deliberate.
  defp keep_stored_secrets(changeset) do
    Enum.reduce(@write_only, changeset, fn field, acc ->
      # `fetch_change/2` rather than `get_change/2`: an empty box casts to a
      # `nil` change, and `get_change/2` cannot tell that apart from no change
      # at all — which is exactly the difference between "clear the password"
      # and "I did not touch it".
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

  # Whitespace around a host, a username or a URL is invisible in the form and
  # fatal at the other end, so it is removed on the way in rather than at every
  # point of use.
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

  defp validate_webhook_url(changeset) do
    case get_field(changeset, :webhook_url) do
      blank when blank in [nil, ""] ->
        changeset

      url ->
        case URI.new(url) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            changeset

          _invalid ->
            add_error(changeset, :webhook_url, "must be a full http:// or https:// URL")
        end
    end
  end

  # Each entry is a single address or a CIDR block. Validating here means a
  # typo is caught in the form rather than at the door, where a malformed entry
  # would simply never match and lock everyone out.
  defp validate_allowed_ips(changeset) do
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
