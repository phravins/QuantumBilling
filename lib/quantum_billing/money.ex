defmodule QuantumBilling.Money do
  @moduledoc """
  Money is integer paise; every rule for reading, rounding and writing it lives
  here.

  ## Why paise

  Amounts used to be whole rupees, so a rate of ₹1,250.50 could not be entered
  and each line's GST was truncated to the rupee. Paise keep the arithmetic in
  integers — exact, fast, and summable in SQL — while carrying the two decimal
  places an invoice needs. Columns are `bigint`: in paise, a 32-bit column
  stops at about ₹2.1 crore.

  ## Rounding

  Half-up, away from zero: 0.5 paise becomes 1. The grand total is then rounded
  to the rupee, as Indian invoices are, and the difference is shown as the
  round-off rather than lost.

  ## Boundaries

  People type rupees (`"1,250.50"`) and payloads want rupees (`1250.50`);
  `parse/1`, `to_input/1` and `to_rupees_decimal/1` are the only crossings.
  """

  @doc """
  Reads a rupee amount as typed into a form, returning paise.

  Accepts a rupee sign, Indian or Western digit grouping, surrounding spaces
  and up to two decimal places. A number is taken as rupees too, so `5000` and
  `"5000"` agree.

  ## Examples

      iex> QuantumBilling.Money.parse("₹ 1,250.50")
      {:ok, 125_050}

      iex> QuantumBilling.Money.parse(18)
      {:ok, 1_800}

      iex> QuantumBilling.Money.parse("12.345")
      :error

  """
  def parse(rupees) when is_integer(rupees), do: {:ok, rupees * 100}

  def parse(%Decimal{} = rupees) do
    paise = Decimal.mult(rupees, 100)

    if Decimal.integer?(paise), do: {:ok, Decimal.to_integer(paise)}, else: :error
  end

  def parse(rupees) when is_float(rupees), do: rupees |> Decimal.from_float() |> parse()

  def parse(rupees) when is_binary(rupees) do
    cleaned = rupees |> String.replace(["₹", ",", " "], "") |> String.trim()

    if Regex.match?(~r/^-?\d+(\.\d{1,2})?$/, cleaned),
      do: cleaned |> Decimal.new() |> parse(),
      else: :error
  end

  def parse(_rupees), do: :error

  @doc """
  Paise as the plain rupee string a form input or a payload carries.

  ## Examples

      iex> QuantumBilling.Money.to_input(125_050)
      "1250.50"

      iex> QuantumBilling.Money.to_input(-5)
      "-0.05"

  """
  def to_input(nil), do: ""

  def to_input(paise) when is_integer(paise) do
    sign = if paise < 0, do: "-", else: ""
    paise = abs(paise)
    fraction = paise |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{sign}#{div(paise, 100)}.#{fraction}"
  end

  @doc """
  Paise as a two-place rupee `Decimal`, for JSON and XML payloads.

  ## Examples

      iex> QuantumBilling.Money.to_rupees_decimal(125_050)
      Decimal.new("1250.50")

  """
  def to_rupees_decimal(nil), do: Decimal.new("0.00")
  def to_rupees_decimal(paise) when is_integer(paise), do: Decimal.new(to_input(paise))

  @doc """
  Quantity × rate, rounded half-up to the paisa.

  `quantity` is a `Decimal` (up to three places), an integer, or a numeric
  string; anything else counts as zero.

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
  Rounds paise to the nearest whole rupee, half-up.

  Returns `{rounded, round_off}` where `rounded = paise + round_off`, so the
  round-off is what an invoice prints: never more than fifty paise either way.

  ## Examples

      iex> QuantumBilling.Money.round_to_rupee(1_180_040)
      {1_180_000, -40}

      iex> QuantumBilling.Money.round_to_rupee(1_180_050)
      {1_180_100, 50}

  """
  def round_to_rupee(paise) when is_integer(paise) do
    rounded = round_half_up(paise, 100) * 100
    {rounded, rounded - paise}
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
