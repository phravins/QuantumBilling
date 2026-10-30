defmodule QuantumBillingWeb.Format do
  @moduledoc """
  Display formatting helpers shared by the list and detail pages.

  Amounts arrive in paise (see `QuantumBilling.Money`).
  """

  alias QuantumBilling.Money

  @doc """
  Formats an amount held in paise using Indian digit grouping (last three
  digits, then pairs), prefixed with the rupee sign.

  ## Options

    * `:decimals` - `0` (the default) rounds half-up to whole rupees, as lists
      and the dashboard show them; `2` shows the paise, as documents do
    * `:space` - whether to put a space after the rupee sign (default `false`)

  ## Examples

      iex> QuantumBillingWeb.Format.rupees(15_000_000)
      "₹1,50,000"

      iex> QuantumBillingWeb.Format.rupees(1_500_050, decimals: 2, space: true)
      "₹ 15,000.50"

      iex> QuantumBillingWeb.Format.rupees(1_500_050)
      "₹15,001"

  """
  def rupees(paise, opts \\ []) when is_integer(paise) do
    space = if Keyword.get(opts, :space, false), do: " ", else: ""

    "₹" <> space <> figure(paise, Keyword.get(opts, :decimals, 0))
  end

  @doc """
  An amount held in paise as a grouped number with no rupee sign, for CSV
  cells and chart labels.

  ## Examples

      iex> QuantumBillingWeb.Format.figure(-12_345_678, 2)
      "-1,23,456.78"

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

  @doc """
  The value a rupee input shows: stored paise as rupees, and anything else —
  what the user typed — exactly as typed.

  ## Examples

      iex> QuantumBillingWeb.Format.money_input(125_050)
      "1250.50"

      iex> QuantumBillingWeb.Format.money_input("1250.5")
      "1250.5"

  """
  def money_input(paise) when is_integer(paise), do: Money.to_input(paise)
  def money_input(typed), do: typed

  @doc """
  A quantity without the trailing zeros its column carries: `2.500` is `2.5`,
  `1.000` is `1`.

  ## Examples

      iex> QuantumBillingWeb.Format.quantity(Decimal.new("2.500"))
      "2.5"

      iex> QuantumBillingWeb.Format.quantity(Decimal.new("10.000"))
      "10"

  """
  def quantity(nil), do: ""
  def quantity(quantity) when is_integer(quantity), do: Integer.to_string(quantity)

  def quantity(%Decimal{} = quantity) do
    quantity |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  def quantity(quantity), do: to_string(quantity)

  @doc """
  Formats a date the way every list and detail page shows it.

  ## Examples

      iex> QuantumBillingWeb.Format.format_date(~D[2024-05-28])
      "28 May 2024"

  """
  def format_date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")
  def format_date(nil), do: "—"

  @doc """
  Says how long ago something happened, the way a feed does.

  Coarse on purpose — "2h ago", never "2 hours and 14 minutes ago". The
  notification bell is read at a glance, and the exact timestamp belongs on the
  record it points at, not in the list pointing there.

  Anything older than a week gets its date instead: "8d ago" tells you less
  than "20 May 2024" does, and by then the feed is history rather than news.

  A timestamp in the future reads as `"just now"` rather than something
  negative — it means the clocks disagree, which is not worth surfacing to
  somebody reading their notifications.

  ## Examples

      iex> QuantumBillingWeb.Format.relative_time(~U[2024-05-28 09:00:00Z], ~U[2024-05-28 11:30:00Z])
      "2h ago"

      iex> QuantumBillingWeb.Format.relative_time(~U[2024-05-28 11:29:50Z], ~U[2024-05-28 11:30:00Z])
      "just now"

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
  Spells an amount held in paise out the way an invoice foot does.

  Indian numbering, so it groups by crore and lakh rather than million and
  billion.

  ## Examples

      iex> QuantumBillingWeb.Format.rupees_in_words(7_080_000)
      "Rupees Seventy Thousand Eight Hundred Only"

      iex> QuantumBillingWeb.Format.rupees_in_words(1_250_050)
      "Rupees Twelve Thousand Five Hundred and Fifty Paise Only"

      iex> QuantumBillingWeb.Format.rupees_in_words(0)
      "Rupees Zero Only"

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
