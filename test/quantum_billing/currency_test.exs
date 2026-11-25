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

  describe "decimal places" do
    test "KWD, BHD and OMR have three and are VAT-only; the rest have two" do
      for code <- Currency.codes() do
        three? = code in ~w(KWD BHD OMR)

        assert Currency.exponent(code) == if(three?, do: 3, else: 2)
        assert Currency.unit(code) == if(three?, do: 1_000, else: 100)
        assert Currency.step(code) == if(three?, do: "0.001", else: "0.01")
        assert Currency.vat_only?(code) == three?
      end
    end

    test "an unknown code falls back to INR's two" do
      assert Currency.exponent(nil) == 2
      assert Currency.unit("XYZ") == 100
    end
  end

  describe "Format.money/3 in three-decimal currencies" do
    test "any non-zero decimals show all three" do
      assert Format.money(12_345, "KWD", decimals: 2) == "KWD 12.345"
      assert Format.money(1_250_500, "BHD", decimals: 2) == "BHD 1,250.500"
      assert Format.money(-1, "OMR", decimals: 2) == "OMR -0.001"
    end

    test "whole units round at 1000" do
      assert Format.money(12_500, "KWD") == "KWD 13"
      assert Format.money(12_499, "KWD") == "KWD 12"
    end

    test "money_input/2 gives the typed form" do
      assert Format.money_input(12_345, "KWD") == "12.345"
      assert Format.money_input(12_345, "AED") == "123.45"
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

    test "three-decimal currencies split at 1000" do
      assert Format.amount_in_words(12_345, "KWD") ==
               "Dinars Twelve and Three Hundred Forty Five Fils Only"

      assert Format.amount_in_words(5_000, "OMR") == "Rials Five Only"
      assert Format.amount_in_words(1_050, "OMR") == "Rials One and Fifty Baisa Only"
    end
  end

  test "chart labels use lakh and crore for INR only" do
    assert DashboardComponents.money_axis_label(250_000_000, "INR") == "₹25L"
    assert DashboardComponents.money_axis_label(250_000_000, "AED") == "AED 2.5M"
    assert DashboardComponents.money_axis_label(150_000, "GBP") == "£1.5K"
    assert DashboardComponents.money_axis_label(1_500_000, "KWD") == "KWD 1.5K"
  end

  test "Money.parse/1 takes any supported sign or code" do
    assert Money.parse("£1,250.50") == {:ok, 125_050}
    assert Money.parse("aed 1,250") == {:ok, 125_000}
    assert Money.parse("-USD 5") == {:ok, -500}
    assert Money.parse("XYZ 5") == :error
  end
end
