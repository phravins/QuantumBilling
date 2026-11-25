defmodule QuantumBilling.MoneyTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Money

  doctest Money

  describe "parse/1" do
    test "reads rupees with paise, grouping and the rupee sign" do
      assert Money.parse("1250.5") == {:ok, 125_050}
      assert Money.parse("12,50,000.75") == {:ok, 125_000_075}
      assert Money.parse(" ₹99.99 ") == {:ok, 9_999}
      assert Money.parse("-40") == {:ok, -4_000}
      assert Money.parse(Decimal.new("0.01")) == {:ok, 1}
    end

    test "refuses what is not an amount" do
      assert Money.parse("") == :error
      assert Money.parse("abc") == :error
      assert Money.parse("1.234") == :error
      assert Money.parse(Decimal.new("1.234")) == :error
      assert Money.parse(nil) == :error
    end
  end

  describe "parse/2" do
    test "reads three decimals in KWD, BHD and OMR" do
      assert Money.parse("12.345", "KWD") == {:ok, 12_345}
      assert Money.parse("BHD 1,250.5", "BHD") == {:ok, 1_250_500}
      assert Money.parse("0.001", "OMR") == {:ok, 1}
      assert Money.parse(12, "OMR") == {:ok, 12_000}
      assert Money.parse(Decimal.new("2.5"), "KWD") == {:ok, 2_500}
    end

    test "refuses more decimals than the currency has" do
      assert Money.parse("12.345", "AED") == :error
      assert Money.parse("12.3456", "KWD") == :error
      assert Money.parse(Decimal.new("0.0005"), "BHD") == :error
    end

    test "two-decimal currencies read as before" do
      assert Money.parse("1,250.50", "AED") == {:ok, 125_050}
      assert Money.parse(12, "GBP") == {:ok, 1_200}
    end
  end

  test "to_input/2 round-trips parse/2 in every currency" do
    for code <- QuantumBilling.Currency.codes(), minor <- [0, 1, 99, 1_000, 12_345, -7] do
      assert {:ok, ^minor} = minor |> Money.to_input(code) |> Money.parse(code)
    end

    assert Money.to_input(12_345, "KWD") == "12.345"
    assert Money.to_input(12_345, "AED") == "123.45"
  end

  test "round_to_whole/2 rounds half-up at the currency's unit" do
    assert Money.round_to_whole(12_499, "KWD") == {12_000, -499}
    assert Money.round_to_whole(12_500, "KWD") == {13_000, 500}
    assert Money.round_to_whole(-12_500, "OMR") == {-13_000, -500}
    assert Money.round_to_whole(150, "AED") == {200, 50}
    assert Money.round_to_rupee(150) == {200, 50}
  end

  test "to_input/1 round-trips parse/1" do
    for paise <- [0, 1, 99, 100, 125_050, -7] do
      assert {:ok, ^paise} = paise |> Money.to_input() |> Money.parse()
    end
  end

  describe "line_amount/2" do
    test "rounds half-up to the paisa" do
      # 2.5 × ₹99.99 = ₹249.975
      assert Money.line_amount(Decimal.new("2.5"), 9_999) == 24_998
      assert Money.line_amount(Decimal.new("0.125"), 100) == 13
      assert Money.line_amount(3, 10_000) == 30_000
      assert Money.line_amount("1.75", 80_000) == 140_000
    end

    test "counts what isn't a quantity as nothing" do
      assert Money.line_amount(nil, 10_000) == 0
      assert Money.line_amount("lots", 10_000) == 0
      assert Money.line_amount(2, nil) == 0
    end
  end

  describe "tax/2" do
    test "rounds half-up rather than truncating" do
      # 18% of ₹249.98 is ₹44.9964.
      assert Money.tax(24_998, 18) == 4_500
      # 5% of ₹0.10 is half a paisa.
      assert Money.tax(10, 5) == 1
      assert Money.tax(1_000_000, 18) == 180_000
      assert Money.tax(1_000, 0) == 0
    end
  end

  describe "round_to_rupee/1" do
    test "rounds to the nearest rupee and reports the difference" do
      assert Money.round_to_rupee(1_180_040) == {1_180_000, -40}
      assert Money.round_to_rupee(1_180_049) == {1_180_000, -49}
      assert Money.round_to_rupee(1_180_050) == {1_180_100, 50}
      assert Money.round_to_rupee(1_180_000) == {1_180_000, 0}
      assert Money.round_to_rupee(-150) == {-200, -50}
    end
  end

  test "to_rupees_decimal/1 carries two places" do
    assert Money.to_rupees_decimal(1_180_000) == Decimal.new("11800.00")
    assert Money.to_rupees_decimal(nil) == Decimal.new("0.00")
  end
end
