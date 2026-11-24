defmodule QuantumBilling.Money do
  @moduledoc """
  Money is integer minor units; every rule for reading, rounding and writing it lives here.

  Columns are `bigint`. A currency has 100 minor units, or 1000 for KWD, BHD
  and OMR (see `QuantumBilling.Currency.exponent/1`). Rounding is half-up, away
  from zero; the grand total may be rounded to the whole unit and the difference
  shown as round-off.

  `parse/2`, `to_input/2` and `to_decimal/2` are the only crossings between
  typed amounts and minor units. The one-argument forms are rupees and paise,
  for the GST paths that only ever work in INR.
  """

  import Ecto.Changeset, only: [put_change: 3, add_error: 3]

  alias QuantumBilling.Currency

  # A leading ISO code, as in "AED 1,250", after an optional minus sign.
  @code_prefix ~r/^(-?)(?:#{Enum.join(QuantumBilling.Currency.codes(), "|")})/i

  @doc """
  Reads a rupee amount as typed into a form, returning paise. See `parse/2`.

  ## Examples

      iex> QuantumBilling.Money.parse("₹ 1,250.50")
      {:ok, 125_050}

      iex> QuantumBilling.Money.parse("AED 1,250")
      {:ok, 125_000}

      iex> QuantumBilling.Money.parse(18)
      {:ok, 1_800}

      iex> QuantumBilling.Money.parse("12.345")
      :error
  """
  def parse(rupees), do: parse(rupees, "INR")

  @doc """
  Reads an amount in `currency` as typed into a form, returning minor units.

  Accepts a currency sign or code (`₹`, `£`, `AED`), Indian or Western
  grouping, spaces and up to the currency's decimals. A number is taken as
  whole units too.

  ## Examples

      iex> QuantumBilling.Money.parse("12.345", "KWD")
      {:ok, 12_345}

      iex> QuantumBilling.Money.parse("BHD 1,250.5", "BHD")
      {:ok, 1_250_500}

      iex> QuantumBilling.Money.parse(12, "OMR")
      {:ok, 12_000}

      iex> QuantumBilling.Money.parse("12.345", "AED")
      :error
  """
  def parse(major, currency) when is_integer(major), do: {:ok, major * Currency.unit(currency)}

  def parse(%Decimal{} = major, currency) do
    minor = Decimal.mult(major, Currency.unit(currency))

    if Decimal.integer?(minor), do: {:ok, Decimal.to_integer(minor)}, else: :error
  end

  def parse(major, currency) when is_float(major),
    do: major |> Decimal.from_float() |> parse(currency)

  def parse(major, currency) when is_binary(major) do
    cleaned =
      major
      |> String.replace(["₹", "£", "€", "$", ",", " "], "")
      |> String.replace(@code_prefix, "\\1")
      |> String.trim()

    if Regex.match?(~r/^-?\d+(\.\d+)?$/, cleaned) and
         decimal_places(cleaned) <= Currency.exponent(currency),
       do: cleaned |> Decimal.new() |> parse(currency),
       else: :error
  end

  def parse(_major, _currency), do: :error

  defp decimal_places(digits) do
    case String.split(digits, ".") do
      [_whole, fraction] -> String.length(fraction)
      [_whole] -> 0
    end
  end

  @doc """
  Casts `field` from `attrs` with `parse/2` in `currency` and puts it on the
  changeset, for an amount whose currency only the parent record knows (an
  Ecto type sees just the one value). A missing key leaves the field alone;
  a blank one sets nil.
  """
  def cast_amount(%Ecto.Changeset{} = changeset, attrs, field, currency) when is_atom(field) do
    case fetch_param(attrs, field) do
      :error ->
        changeset

      {:ok, blank} when blank in [nil, ""] ->
        put_change(changeset, field, nil)

      {:ok, raw} ->
        case parse(raw, currency) do
          {:ok, minor} -> put_change(changeset, field, minor)
          :error -> add_error(changeset, field, amount_error(currency))
        end
    end
  end

  defp fetch_param(attrs, field) when is_map(attrs) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, field)
    end
  end

  defp fetch_param(_attrs, _field), do: :error

  @doc """
  The validation message for an amount `parse/2` refused in `currency`.

  ## Examples

      iex> QuantumBilling.Money.amount_error("KWD")
      "must be an amount with at most three decimal places"
  """
  def amount_error(currency) do
    places = if Currency.exponent(currency) == 3, do: "three", else: "two"
    "must be an amount with at most #{places} decimal places"
  end

  @doc """
  Paise as the plain rupee string a form input or a payload carries. See `to_input/2`.

  ## Examples

      iex> QuantumBilling.Money.to_input(125_050)
      "1250.50"

      iex> QuantumBilling.Money.to_input(-5)
      "-0.05"

  """
  def to_input(paise), do: to_input(paise, "INR")

  @doc """
  Minor units in `currency` as the plain string a form input or a payload carries.

  ## Examples

      iex> QuantumBilling.Money.to_input(12_345, "KWD")
      "12.345"

      iex> QuantumBilling.Money.to_input(-5, "OMR")
      "-0.005"

  """
  def to_input(nil, _currency), do: ""

  def to_input(minor, currency) when is_integer(minor) do
    exponent = Currency.exponent(currency)
    unit = Integer.pow(10, exponent)
    sign = if minor < 0, do: "-", else: ""
    minor = abs(minor)
    fraction = minor |> rem(unit) |> Integer.to_string() |> String.pad_leading(exponent, "0")

    "#{sign}#{div(minor, unit)}.#{fraction}"
  end

  @doc """
  Paise as a two-place rupee `Decimal`, for JSON and XML payloads.

  ## Examples

      iex> QuantumBilling.Money.to_rupees_decimal(125_050)
      Decimal.new("1250.50")

  """
  def to_rupees_decimal(paise), do: to_decimal(paise, "INR")

  @doc """
  Minor units as a `Decimal` of whole units with the currency's places.

  ## Examples

      iex> QuantumBilling.Money.to_decimal(12_345, "KWD")
      Decimal.new("12.345")

  """
  def to_decimal(nil, currency), do: Decimal.new(to_input(0, currency))

  def to_decimal(minor, currency) when is_integer(minor),
    do: Decimal.new(to_input(minor, currency))

  @doc """
  Quantity × rate, rounded half-up to the paisa.

  `quantity` is a `Decimal`, an integer or a numeric string; anything else is zero.

  ## Examples

      iex> QuantumBilling.Money.line_amount(Decimal.new("2.5"), 9_999)
      24_998
  """
  def line_amount(quantity, rate_paise) when is_integer(rate_paise) do
    case quantity(quantity) do
      nil ->
        0

      quantity ->
        quantity
        |> Decimal.mult(rate_paise)
        |> Decimal.round(0, :half_up)
        |> Decimal.to_integer()
    end
  end

  def line_amount(_quantity, _rate_paise), do: 0

  @doc """
  The tax at `rate` percent on `amount_paise`, rounded half-up to the paisa.

  ## Examples

      iex> QuantumBilling.Money.tax(24_998, 18)
      4_500

  """
  def tax(amount_paise, rate) when is_integer(amount_paise) and is_integer(rate) do
    round_half_up(amount_paise * rate, 100)
  end

  def tax(_amount_paise, _rate), do: 0

  @doc """
  The tax at `rate_bp` basis points (750 is 7.5%) on `amount`, rounded half-up.

  ## Examples

      iex> QuantumBilling.Money.tax_bp(10_000, 750)
      750

      iex> QuantumBilling.Money.tax_bp(333, 500)
      17

  """
  def tax_bp(amount, rate_bp) when is_integer(amount) and is_integer(rate_bp),
    do: round_half_up(amount * rate_bp, 10_000)

  def tax_bp(_amount, _rate_bp), do: 0

  @doc """
  The amount before tax inside a tax-inclusive `gross`, rounded half-up.

  ## Examples

      iex> QuantumBilling.Money.net_of_tax(10_500, 500)
      10_000

  """
  def net_of_tax(gross, rate_bp) when is_integer(gross) and is_integer(rate_bp),
    do: round_half_up(gross * 10_000, 10_000 + rate_bp)

  @doc """
  Rounds paise to the nearest whole rupee, half-up: `{rounded, round_off}`.

  ## Examples

      iex> QuantumBilling.Money.round_to_rupee(1_180_040)
      {1_180_000, -40}

      iex> QuantumBilling.Money.round_to_rupee(1_180_050)
      {1_180_100, 50}
  """
  def round_to_rupee(paise) when is_integer(paise), do: round_to_whole(paise, "INR")

  @doc """
  Rounds minor units to the nearest whole unit of `currency`, half-up:
  `{rounded, round_off}`.

  ## Examples

      iex> QuantumBilling.Money.round_to_whole(12_500, "KWD")
      {13_000, 500}

      iex> QuantumBilling.Money.round_to_whole(-12_499, "BHD")
      {-12_000, 499}
  """
  def round_to_whole(minor, currency) when is_integer(minor) do
    unit = Currency.unit(currency)
    rounded = round_half_up(minor, unit) * unit
    {rounded, rounded - minor}
  end

  @doc """
  Reads a quantity as a `Decimal`, or `nil` when it isn't a number.

  ## Examples

      iex> QuantumBilling.Money.quantity("2.5")
      Decimal.new("2.5")

  """
  def quantity(%Decimal{} = quantity), do: quantity
  def quantity(quantity) when is_integer(quantity), do: Decimal.new(quantity)
  def quantity(quantity) when is_float(quantity), do: Decimal.from_float(quantity)

  def quantity(quantity) when is_binary(quantity) do
    case Decimal.parse(String.trim(quantity)) do
      {decimal, ""} -> decimal
      _not_a_number -> nil
    end
  end

  def quantity(_quantity), do: nil

  # Integer division rounding half away from zero.
  defp round_half_up(numerator, denominator) when numerator >= 0,
    do: div(numerator * 2 + denominator, denominator * 2)

  defp round_half_up(numerator, denominator), do: -round_half_up(-numerator, denominator)
end
