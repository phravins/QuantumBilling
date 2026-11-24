defmodule QuantumBilling.Currency do
  @moduledoc """
  The currencies a business can bill in. Amounts are integer minor units
  (paise, fils, baisa, pence, cents) everywhere.

  Each has a symbol, the unit names used for amounts in words, a digit grouping
  (Indian `1,50,000` for INR, Western `150,000` for the rest) and an ISO 4217
  exponent: 2 decimals for most, 3 for KWD, BHD and OMR (1000 fils or baisa).

  Three-decimal currencies are VAT-only: the GST paths (e-invoice, e-way bill,
  GSTR-1, UPI) work in rupees and paise.
  """

  @currencies [
    %{
      code: "INR",
      symbol: "₹",
      name: "Indian Rupee",
      major: "Rupees",
      minor: "Paise",
      grouping: :indian
    },
    %{
      code: "AED",
      symbol: "AED",
      name: "UAE Dirham",
      major: "Dirhams",
      minor: "Fils",
      grouping: :western
    },
    %{
      code: "SAR",
      symbol: "SAR",
      name: "Saudi Riyal",
      major: "Riyals",
      minor: "Halalas",
      grouping: :western
    },
    %{
      code: "QAR",
      symbol: "QAR",
      name: "Qatari Riyal",
      major: "Riyals",
      minor: "Dirhams",
      grouping: :western
    },
    %{
      code: "KWD",
      symbol: "KWD",
      name: "Kuwaiti Dinar",
      major: "Dinars",
      minor: "Fils",
      grouping: :western,
      exponent: 3
    },
    %{
      code: "BHD",
      symbol: "BHD",
      name: "Bahraini Dinar",
      major: "Dinars",
      minor: "Fils",
      grouping: :western,
      exponent: 3
    },
    %{
      code: "OMR",
      symbol: "OMR",
      name: "Omani Rial",
      major: "Rials",
      minor: "Baisa",
      grouping: :western,
      exponent: 3
    },
    %{
      code: "GBP",
      symbol: "£",
      name: "Pound Sterling",
      major: "Pounds",
      minor: "Pence",
      grouping: :western
    },
    %{code: "EUR", symbol: "€", name: "Euro", major: "Euros", minor: "Cents", grouping: :western},
    %{
      code: "USD",
      symbol: "$",
      name: "US Dollar",
      major: "Dollars",
      minor: "Cents",
      grouping: :western
    }
  ]

  @by_code Map.new(@currencies, &{&1.code, &1})
  @codes Enum.map(@currencies, & &1.code)
  @default "INR"

  def default, do: @default

  @doc "Supported ISO codes, INR first."
  def codes, do: @codes

  @doc "A currency by code; INR for nil or an unknown code."
  def get(code) when is_binary(code),
    do: Map.get(@by_code, String.upcase(code), @by_code[@default])

  def get(_code), do: @by_code[@default]

  def supported?(code) when is_binary(code), do: Map.has_key?(@by_code, code)
  def supported?(_code), do: false

  def symbol(code), do: get(code).symbol

  @doc """
  Decimal places in `code` (ISO 4217): 3 for KWD, BHD and OMR, 2 for the rest.

  ## Examples

      iex> QuantumBilling.Currency.exponent("KWD")
      3

      iex> QuantumBilling.Currency.exponent("AED")
      2
  """
  def exponent(code), do: Map.get(get(code), :exponent, 2)

  @doc "Minor units in one whole unit: 100, or 1000 for a three-decimal currency."
  def unit(code), do: Integer.pow(10, exponent(code))

  @doc "The `step` of an amount input: `\"0.01\"` or `\"0.001\"`."
  def step(code), do: "0." <> String.duplicate("0", exponent(code) - 1) <> "1"

  @doc "Whether `code` needs the VAT regime: the GST paths work only in two decimals."
  def vat_only?(code), do: exponent(code) != 2

  @doc """
  The label Settings shows and stores, e.g. `"INR (₹) - Indian Rupee"` or
  `"AED - UAE Dirham"` (no symbol when it is the code itself).
  """
  def label(code) do
    %{code: code, symbol: symbol, name: name} = get(code)
    if symbol == code, do: "#{code} - #{name}", else: "#{code} (#{symbol}) - #{name}"
  end

  def labels, do: Enum.map(@codes, &label/1)

  @doc "The code in a stored Settings label: `\"AED - UAE Dirham\"` gives `\"AED\"`."
  def code_from_label(label) when is_binary(label) do
    code = label |> String.slice(0, 3) |> String.upcase()
    if supported?(code), do: code, else: @default
  end

  def code_from_label(_label), do: @default

  @doc "Whether the symbol is letters (`AED`), so it needs a space before the figure."
  def letter_symbol?(code), do: get(code).symbol =~ ~r/^[A-Z]+$/
end
