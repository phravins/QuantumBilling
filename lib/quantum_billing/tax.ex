defmodule QuantumBilling.Tax do
  @moduledoc """
  The tax engine. A business charges India GST (`"gst"`) or VAT (`"vat"`);
  each invoice keeps the regime it was raised under, so changing the setting
  never changes an issued invoice.

  `totals/2` works out an invoice's totals under its regime. The VAT
  countries, their tax-number formats and their preset rates live here too, as
  does `ensure_gst/1`, which keeps the India GST features (IRP e-invoice,
  e-way bills, GSTR-1, the HSN finder) off VAT businesses and invoices.
  """

  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Tax.GST
  alias QuantumBilling.Tax.VAT

  @regimes [{"gst", "India GST"}, {"vat", "VAT"}]

  @categories [
    {"standard", "Standard"},
    {"reduced", "Reduced"},
    {"zero", "Zero-rated"},
    {"exempt", "Exempt"},
    {"reverse_charge", "Reverse charge"},
    {"out_of_scope", "Out of scope"}
  ]

  # Categories that never carry tax, whatever rate is entered.
  @untaxed ~w(zero exempt reverse_charge out_of_scope)

  @eu ~w(BE DE ES FR IE IT NL)

  @gst_only %{
    e_invoice: "IRP e-invoicing is part of India GST; this business charges VAT.",
    e_way_bills: "E-way bills are part of India GST; this business charges VAT.",
    gstr1: "GSTR-1 is an India GST return; this business charges VAT.",
    hsn_finder: "The HSN finder is for India GST rates; this business charges VAT."
  }

  # ISO-2 code, name, tax-number format, presets as {name, category, rate_bp}.
  @countries [
    {"AE", "United Arab Emirates", ~r/^\d{15}$/,
     [
       {"Standard 5%", "standard", 500},
       {"Zero-rated", "zero", 0},
       {"Exempt", "exempt", 0},
       {"Reverse charge", "reverse_charge", 0}
     ]},
    {"SA", "Saudi Arabia", ~r/^\d{15}$/,
     [{"Standard 15%", "standard", 1500}, {"Zero-rated", "zero", 0}, {"Exempt", "exempt", 0}]},
    {"BH", "Bahrain", ~r/^\d{15}$/,
     [{"Standard 10%", "standard", 1000}, {"Zero-rated", "zero", 0}]},
    {"OM", "Oman", ~r/^OM\d{10}$/,
     [{"Standard 5%", "standard", 500}, {"Zero-rated", "zero", 0}, {"Exempt", "exempt", 0}]},
    {"GB", "United Kingdom", ~r/^GB(\d{9}|\d{12})$/,
     [
       {"Standard 20%", "standard", 2000},
       {"Reduced 5%", "reduced", 500},
       {"Zero-rated", "zero", 0},
       {"Exempt", "exempt", 0}
     ]},
    {"BE", "Belgium", nil, [{"Standard 21%", "standard", 2100}, {"Reduced 6%", "reduced", 600}]},
    {"DE", "Germany", nil, [{"Standard 19%", "standard", 1900}, {"Reduced 7%", "reduced", 700}]},
    {"ES", "Spain", nil, [{"Standard 21%", "standard", 2100}, {"Reduced 10%", "reduced", 1000}]},
    {"FR", "France", nil, [{"Standard 20%", "standard", 2000}, {"Reduced 5.5%", "reduced", 550}]},
    {"IE", "Ireland", nil,
     [{"Standard 23%", "standard", 2300}, {"Reduced 13.5%", "reduced", 1350}]},
    {"IT", "Italy", nil, [{"Standard 22%", "standard", 2200}, {"Reduced 10%", "reduced", 1000}]},
    {"NL", "Netherlands", nil,
     [{"Standard 21%", "standard", 2100}, {"Reduced 9%", "reduced", 900}]}
  ]

  # Every EU preset also zero-rates, exempts and reverse-charges.
  @eu_extras [
    {"Zero-rated", "zero", 0},
    {"Exempt", "exempt", 0},
    {"Intra-EU reverse charge", "reverse_charge", 0}
  ]

  @doc """
  The invoice totals for `items`. `ctx` holds `:regime` plus, for GST,
  `:intra_state?`, and for VAT `:reverse_charge` and `:prices_include_tax`.
  `:round_to_whole_units` false leaves the total unrounded under either.
  """
  def totals(items, %{regime: "vat"} = ctx), do: VAT.totals(items, ctx)

  def totals(items, ctx) do
    items
    |> GST.totals(Map.get(ctx, :intra_state?, true))
    |> Map.merge(%{vat_amount: 0, tax_breakdown: []})
    |> unrounded(Map.get(ctx, :round_to_whole_units, true))
  end

  defp unrounded(totals, false),
    do: %{totals | grand_total: totals.grand_total - totals.round_off, round_off: 0}

  defp unrounded(totals, _round?), do: totals

  def regimes, do: @regimes
  def regime_codes, do: Enum.map(@regimes, &elem(&1, 0))

  def vat?(regime), do: regime == "vat"

  def categories, do: @categories
  def category_codes, do: Enum.map(@categories, &elem(&1, 0))

  def category_label(code),
    do: Enum.find_value(@categories, code, fn {c, label} -> if c == code, do: label end)

  @doc "Whether a category never carries tax (zero-rated, exempt and so on)."
  def untaxed_category?(category), do: category in @untaxed

  @doc "The basis points a line is taxed at: none for untaxed categories."
  def effective_bp(%{tax_category: category, tax_rate_bp: rate_bp}) do
    if untaxed_category?(category) or not is_integer(rate_bp), do: 0, else: rate_bp
  end

  @doc """
  Basis points as a percentage without trailing zeros.

  ## Examples

      iex> QuantumBilling.Tax.percent(750)
      "7.5"

      iex> QuantumBilling.Tax.percent(2000)
      "20"

  """
  def percent(rate_bp) when is_integer(rate_bp) do
    whole = div(rate_bp, 100)

    case rem(rate_bp, 100) do
      0 ->
        Integer.to_string(whole)

      fraction ->
        "#{whole}." <> String.trim_trailing(String.pad_leading("#{fraction}", 2, "0"), "0")
    end
  end

  def percent(_rate_bp), do: "0"

  def percent_label(rate_bp), do: percent(rate_bp) <> "%"

  @doc "A VAT breakdown row's label: its name, with the percentage unless the name says it."
  def breakdown_label(%{"name" => name, "category" => category, "rate_bp" => rate_bp}) do
    if untaxed_category?(category) or String.contains?(name, percent_label(rate_bp)),
      do: name,
      else: "#{name} (#{percent_label(rate_bp)})"
  end

  @doc """
  `:ok` when the India GST features apply: the business charges GST and
  `invoice`, when given, was raised under GST. Else `{:error, :gst_only}`.
  """
  def ensure_gst(invoice \\ nil) do
    if gst_invoice?(invoice) and not Organization.vat?(Settings.get_organization()),
      do: :ok,
      else: {:error, :gst_only}
  end

  defp gst_invoice?(%{tax_regime: "vat"}), do: false
  defp gst_invoice?(_gst_or_none), do: true

  @doc "Why `feature` (`:e_invoice`, `:e_way_bills`, `:gstr1`, `:hsn_finder`) is refused under VAT."
  def gst_only_message(feature), do: Map.fetch!(@gst_only, feature)

  @doc "The note a VAT invoice prints under its totals, or nil."
  def reverse_charge_legend(%{tax_regime: "vat", reverse_charge: true}),
    do: "Reverse charge: the customer is to account for the VAT."

  def reverse_charge_legend(_invoice), do: nil

  @doc """
  Reads a typed percentage as basis points: `"7.5"` is 750. Two decimals at most.
  """
  def parse_percent(value) when is_integer(value), do: {:ok, value * 100}

  def parse_percent(value) when is_binary(value) do
    cleaned = value |> String.replace("%", "") |> String.trim()

    with true <- Regex.match?(~r/^\d{1,3}(\.\d{1,2})?$/, cleaned),
         {decimal, ""} <- Decimal.parse(cleaned) do
      {:ok, decimal |> Decimal.mult(100) |> Decimal.to_integer()}
    else
      _invalid -> :error
    end
  end

  def parse_percent(%Decimal{} = value),
    do: value |> Decimal.to_string(:normal) |> parse_percent()

  def parse_percent(_value), do: :error

  @doc "The VAT countries as `{code, name}`."
  def countries, do: Enum.map(@countries, fn {code, name, _format, _presets} -> {code, name} end)

  def country_codes, do: Enum.map(@countries, &elem(&1, 0))

  def country_name(code),
    do: Enum.find_value(@countries, code, fn {c, name, _, _} -> if c == code, do: name end)

  @doc "The rates a country starts with, as `{name, category, rate_bp}`."
  def presets(code) do
    case List.keyfind(@countries, code, 0) do
      {code, _name, _format, presets} when code in @eu -> presets ++ @eu_extras
      {_code, _name, _format, presets} -> presets
      nil -> [{"Standard", "standard", 0}, {"Zero-rated", "zero", 0}, {"Exempt", "exempt", 0}]
    end
  end

  @doc """
  Whether `number` looks like a VAT number for `country`: a UAE TRN is 15
  digits, a UK number `GB` and 9 or 12 digits, an EU number its country prefix
  and 2 to 13 letters or digits. Elsewhere 3 to 20 letters or digits.
  """
  def tax_number_valid?(country, number) when is_binary(number) do
    number = normalize_tax_number(number)

    case List.keyfind(@countries, country, 0) do
      {code, _name, nil, _presets} -> Regex.match?(~r/^#{code}[A-Z0-9]{2,13}$/, number)
      {_code, _name, format, _presets} -> Regex.match?(format, number)
      nil -> Regex.match?(~r/^[A-Z0-9]{3,20}$/, number)
    end
  end

  def tax_number_valid?(_country, _number), do: false

  @doc "A tax number without spaces or dashes, upper-cased."
  def normalize_tax_number(number) when is_binary(number),
    do: number |> String.replace([" ", "-", "."], "") |> String.upcase()

  def normalize_tax_number(number), do: number

  @doc "Changeset check for a tax number in `field`, against `country`."
  def validate_tax_number(changeset, field, country) do
    changeset
    |> Ecto.Changeset.update_change(field, &normalize_tax_number/1)
    |> Ecto.Changeset.validate_change(field, fn ^field, number ->
      if tax_number_valid?(country, number),
        do: [],
        else: [{field, "doesn't look like a #{country_name(country) || country} VAT number"}]
    end)
  end
end
