defmodule QuantumBilling.CurrencyTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Currency
  alias QuantumBilling.Money
  alias QuantumBillingWeb.Format
  alias QuantumBillingWeb.DashboardComponents

  describe "labels" do
    test "keep the stored INR label and add the others" do
      assert Currency.label("INR") == "INR (₹) - Indian Rupee"
      assert Currency.label("AED") == "AED - UAE Dirham"
      assert Currency.label("GBP") == "GBP (£) - Pound Sterling"
      assert length(Currency.labels()) == length(Currency.codes())
    end

    test "read back to their code, unknown ones to INR" do
      for code <- Currency.codes(),
          do: assert(Currency.code_from_label(Currency.label(code)) == code)

      assert Currency.code_from_label("Bitcoin") == "INR"
      assert Currency.code_from_label(nil) == "INR"
    end
  end

  describe "Format.money/3" do
    test "INR keeps Indian grouping" do
      assert Format.money(15_000_000, "INR") == "₹1,50,000"
      assert Format.money(15_000_000, nil) == Format.rupees(15_000_000)
    end

    test "other currencies group in thousands" do
      assert Format.money(15_000_050, "GBP", decimals: 2) == "£150,000.50"
      assert Format.money(15_000_000, "USD") == "$150,000"
    end

    test "a letter symbol always takes a space" do
      assert Format.money(125_000, "AED", decimals: 2) == "AED 1,250.00"
      assert Format.money(-125_000, "SAR") == "SAR -1,250"
    end
  end

  describe "Format.amount_in_words/2" do
    test "INR is unchanged" do
      assert Format.amount_in_words(15_000_000, "INR") == Format.rupees_in_words(15_000_000)
    end

    test "other currencies use their own units and Western scale" do
      assert Format.amount_in_words(105_000, "AED") == "Dirhams One Thousand Fifty Only"
      assert Format.amount_in_words(100_050, "AED") == "Dirhams One Thousand and Fifty Fils Only"

      assert Format.amount_in_words(250_000_000, "GBP") ==
               "Pounds Two Million Five Hundred Thousand Only"

      assert Format.amount_in_words(0, "EUR") == "Euros Zero Only"
    end
  end

  test "chart labels use lakh and crore for INR only" do
    assert DashboardComponents.money_axis_label(250_000_000, "INR") == "₹25L"
    assert DashboardComponents.money_axis_label(250_000_000, "AED") == "AED 2.5M"
    assert DashboardComponents.money_axis_label(150_000, "GBP") == "£1.5K"
  end

  test "Money.parse/1 takes any supported sign or code" do
    assert Money.parse("£1,250.50") == {:ok, 125_050}
    assert Money.parse("aed 1,250") == {:ok, 125_000}
    assert Money.parse("-USD 5") == {:ok, -500}
    assert Money.parse("XYZ 5") == :error
  end
end
