defmodule QuantumBillingWeb.Format do
  @moduledoc """
  Display formatting helpers shared by the list and detail pages.
  """

  @doc """
  Formats an integer rupee amount using Indian digit grouping (last three
  digits, then pairs), prefixed with the rupee sign.

  ## Options

    * `:decimals` - number of decimal places to render (default `0`)
    * `:space` - whether to put a space after the rupee sign (default `false`)

  ## Examples

      iex> QuantumBillingWeb.Format.rupees(150_000)
      "₹1,50,000"

      iex> QuantumBillingWeb.Format.rupees(15_000, decimals: 2, space: true)
      "₹ 15,000.00"

  """
  def rupees(amount, opts \\ []) when is_integer(amount) do
    decimals = Keyword.get(opts, :decimals, 0)
    space = if Keyword.get(opts, :space, false), do: " ", else: ""

    fraction =
      if decimals > 0 do
        "." <> String.duplicate("0", decimals)
      else
        ""
      end

    "₹" <> space <> group_indian(amount) <> fraction
  end

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
  Spells a rupee amount out the way an invoice foot does.

  Indian numbering, so it groups by crore and lakh rather than million and
  billion.

  ## Examples

      iex> QuantumBillingWeb.Format.rupees_in_words(70_800)
      "Rupees Seventy Thousand Eight Hundred Only"

      iex> QuantumBillingWeb.Format.rupees_in_words(0)
      "Rupees Zero Only"

  """
  def rupees_in_words(amount) when is_integer(amount) and amount < 0 do
    "Minus " <> rupees_in_words(-amount)
  end

  def rupees_in_words(0), do: "Rupees Zero Only"

  def rupees_in_words(amount) when is_integer(amount) do
    "Rupees " <> String.trim(in_words(amount)) <> " Only"
  end

  # Indian grouping: crore, then lakh, then the last three digits read as a
  # Western hundred.
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

  # Everything below twenty has its own name, which is why the table runs that
  # far rather than stopping at nine.
  defp in_words(n) when n >= 20 do
    " " <> Enum.at(@tens, div(n, 10)) <> in_words(rem(n, 10))
  end

  defp in_words(n), do: " " <> Enum.at(@ones, n)

  # Groups the last three digits, then every two digits above that:
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
