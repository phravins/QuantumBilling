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
