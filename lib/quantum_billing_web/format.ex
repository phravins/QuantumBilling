defmodule QuantumBillingWeb.Format do
  @moduledoc "Display formatting helpers. Amounts are in paise (see `QuantumBilling.Money`)."

  alias QuantumBilling.Money

  @doc """
  Formats paise as rupees with Indian digit grouping, e.g. `"₹1,50,000"`.

  Options: `:decimals` (0 rounds to whole rupees, 2 shows paise) and `:space`
  (a space after the rupee sign).
  """
  def rupees(paise, opts \\ []) when is_integer(paise) do
    space = if Keyword.get(opts, :space, false), do: " ", else: ""

    "₹" <> space <> figure(paise, Keyword.get(opts, :decimals, 0))
  end

  @doc """
  Paise as a grouped number without the rupee sign, e.g. `"-1,23,456.78"`.
  """
  def figure(paise, decimals \\ 0)

  def figure(paise, 0) when is_integer(paise) do
    {rupees, _round_off} = Money.round_to_rupee(paise)
    group_indian(div(rupees, 100))
  end

  def figure(paise, 2) when is_integer(paise) do
    sign = if paise < 0, do: "-", else: ""
    paise = abs(paise)
    fraction = paise |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")

    sign <> group_indian(div(paise, 100)) <> "." <> fraction
  end

  @doc "The value a rupee input shows: stored paise as rupees, typed text as is."
  def money_input(paise) when is_integer(paise), do: Money.to_input(paise)
  def money_input(typed), do: typed

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
