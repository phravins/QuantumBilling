defmodule QuantumBillingWeb.Format do
  @moduledoc "Display formatting helpers. Amounts are in minor units (see `QuantumBilling.Money`)."

  alias QuantumBilling.Currency
  alias QuantumBilling.Money

  @doc """
  Formats paise as rupees with Indian digit grouping, e.g. `"₹1,50,000"`.

  Options: `:decimals` (0 rounds to whole rupees, 2 shows paise) and `:space`
  (a space after the rupee sign).
  """
  def rupees(paise, opts \\ []) when is_integer(paise), do: money(paise, "INR", opts)

  @doc """
  Formats minor units in `currency` (an ISO code; nil is INR), e.g.
  `"₹1,50,000"`, `"£150,000.00"`, `"AED 150,000.00"`, `"KWD 1,250.500"`.

  Options as `rupees/2`, except that any non-zero `:decimals` shows all of the
  currency's places: two, or three for KWD, BHD and OMR. A letter symbol such
  as `AED` always takes a space.
  """
  def money(minor, currency, opts \\ []) when is_integer(minor) do
    %{symbol: symbol, grouping: grouping} = Currency.get(currency)

    space =
      if Keyword.get(opts, :space, false) or Currency.letter_symbol?(currency),
        do: " ",
        else: ""

    symbol <> space <> figure(minor, Keyword.get(opts, :decimals, 0), grouping, currency)
  end

  @doc "The currency symbol for an ISO code, for column headings such as `Rate (₹)`."
  def currency_symbol(currency), do: Currency.symbol(currency)

  @doc """
  Minor units as a grouped number without a symbol, e.g. `"-1,23,456.78"`.

  `decimals` 0 rounds to the whole unit; anything else shows the currency's
  places. Grouping is `:indian` (default) or `:western`; `currency` (INR by
  default) sets the places and the whole unit.
  """
  def figure(minor, decimals \\ 0, grouping \\ :indian, currency \\ "INR")

  def figure(minor, 0, grouping, currency) when is_integer(minor) do
    {whole, _round_off} = Money.round_to_whole(minor, currency)
    group(div(whole, Currency.unit(currency)), grouping)
  end

  def figure(minor, _decimals, grouping, currency) when is_integer(minor) do
    exponent = Currency.exponent(currency)
    unit = Currency.unit(currency)
    sign = if minor < 0, do: "-", else: ""
    minor = abs(minor)
    fraction = minor |> rem(unit) |> Integer.to_string() |> String.pad_leading(exponent, "0")

    sign <> group(div(minor, unit), grouping) <> "." <> fraction
  end

  @doc "The value an amount input shows: stored minor units in `currency`, typed text as is."
  def money_input(minor, currency) when is_integer(minor), do: Money.to_input(minor, currency)
  def money_input(typed, _currency), do: typed

  @doc """
  A quantity without trailing zeros: `2.500` becomes `"2.5"`.
  """
  def quantity(nil), do: ""
  def quantity(quantity) when is_integer(quantity), do: Integer.to_string(quantity)

  def quantity(%Decimal{} = quantity) do
    quantity |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  def quantity(quantity), do: to_string(quantity)

  @doc """
  Formats a date as `"28 May 2024"`.
  """
  def format_date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")
  def format_date(nil), do: "—"

  @doc """
  How long ago, coarsely ("2h ago"). Over a week shows the date; the future is "just now".
  """
  def relative_time(at, now \\ DateTime.utc_now())

  def relative_time(%DateTime{} = at, %DateTime{} = now) do
    case DateTime.diff(now, at, :second) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds when seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      _older -> format_date(DateTime.to_date(at))
    end
  end

  def relative_time(nil, _now), do: "—"

  @ones ~w(Zero One Two Three Four Five Six Seven Eight Nine Ten Eleven Twelve
           Thirteen Fourteen Fifteen Sixteen Seventeen Eighteen Nineteen)

  @tens ~w(_ _ Twenty Thirty Forty Fifty Sixty Seventy Eighty Ninety)

  @doc """
  Spells paise out in Indian numbering, e.g. "Rupees Seventy Thousand Eight Hundred Only".
  """
  def rupees_in_words(paise) when is_integer(paise) and paise < 0 do
    "Minus " <> rupees_in_words(-paise)
  end

  def rupees_in_words(0), do: "Rupees Zero Only"

  def rupees_in_words(paise) when paise < 100 do
    String.trim(in_words(paise)) <> " Paise Only"
  end

  def rupees_in_words(paise) when is_integer(paise) do
    rupees = "Rupees " <> String.trim(in_words(div(paise, 100)))

    case rem(paise, 100) do
      0 -> rupees <> " Only"
      fraction -> rupees <> " and " <> String.trim(in_words(fraction)) <> " Paise Only"
    end
  end

  @doc """
  Spells an amount out in `currency`: INR as `rupees_in_words/1`, others in
  Western numbering, e.g. "Dirhams One Thousand and Fifty Fils Only" or
  "Dinars Twelve and Three Hundred Forty Five Fils Only".
  """
  def amount_in_words(minor, currency) when is_integer(minor) do
    case Currency.get(currency) do
      %{code: "INR"} ->
        rupees_in_words(minor)

      %{major: major, minor: minor_name} ->
        western_words(minor, Currency.unit(currency), major, minor_name)
    end
  end

  defp western_words(minor, unit, major, minor_name) when minor < 0,
    do: "Minus " <> western_words(-minor, unit, major, minor_name)

  defp western_words(0, _unit, major, _minor_name), do: major <> " Zero Only"

  defp western_words(minor, unit, _major, minor_name) when minor < unit,
    do: String.trim(western(minor)) <> " " <> minor_name <> " Only"

  defp western_words(minor, unit, major, minor_name) do
    whole = major <> " " <> String.trim(western(div(minor, unit)))

    case rem(minor, unit) do
      0 ->
        whole <> " Only"

      fraction ->
        whole <> " and " <> String.trim(western(fraction)) <> " " <> minor_name <> " Only"
    end
  end

  # Western grouping: billion, million, thousand, then hundreds.
  defp western(n) when n >= 1_000_000_000,
    do: western(div(n, 1_000_000_000)) <> " Billion" <> western(rem(n, 1_000_000_000))

  defp western(n) when n >= 1_000_000,
    do: western(div(n, 1_000_000)) <> " Million" <> western(rem(n, 1_000_000))

  defp western(n) when n >= 1_000,
    do: western(div(n, 1_000)) <> " Thousand" <> western(rem(n, 1_000))

  defp western(n), do: in_words(n)

  # Indian grouping: crore, lakh, then hundreds.
  defp in_words(0), do: ""

  defp in_words(n) when n >= 10_000_000 do
    in_words(div(n, 10_000_000)) <> " Crore" <> in_words(rem(n, 10_000_000))
  end

  defp in_words(n) when n >= 100_000 do
    in_words(div(n, 100_000)) <> " Lakh" <> in_words(rem(n, 100_000))
  end

  defp in_words(n) when n >= 1_000 do
    in_words(div(n, 1_000)) <> " Thousand" <> in_words(rem(n, 1_000))
  end

  defp in_words(n) when n >= 100 do
    in_words(div(n, 100)) <> " Hundred" <> in_words(rem(n, 100))
  end

  defp in_words(n) when n >= 20 do
    " " <> Enum.at(@tens, div(n, 10)) <> in_words(rem(n, 10))
  end

  defp in_words(n), do: " " <> Enum.at(@ones, n)

  # 1500000 -> "1,500,000"
  defp group(amount, :western) do
    sign = if amount < 0, do: "-", else: ""

    digits =
      amount
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    sign <> digits
  end

  defp group(amount, _indian), do: group_indian(amount)

  # 1500000 -> "15,00,000"
  defp group_indian(amount) do
    digits = amount |> abs() |> Integer.to_string()
    sign = if amount < 0, do: "-", else: ""
    len = String.length(digits)

    {rest, last3} = if len > 3, do: String.split_at(digits, len - 3), else: {"", digits}

    grouped_rest =
      rest
      |> String.reverse()
      |> String.replace(~r/(\d{2})(?=\d)/, "\\1,")
      |> String.reverse()

    sign <> if(grouped_rest == "", do: last3, else: grouped_rest <> "," <> last3)
  end
end
