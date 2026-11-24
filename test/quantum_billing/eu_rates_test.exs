defmodule QuantumBilling.EURatesTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Tax
  alias QuantumBilling.Tax.EURates

  describe "EURates metadata and provenance" do
    test "provides official data source and verification date" do
      assert EURates.source() =~ "Taxes in Europe Database"
      assert is_binary(EURates.verified_on())
    end

    test "covers all 27 EU member states" do
      states = EURates.member_states()
      assert length(states) == 27
      assert "DE" in states
      assert "FR" in states
      assert "BE" in states
      assert "ES" in states
      assert "IT" in states
      assert "IE" in states
      assert "NL" in states
      assert "EE" in states
      assert "RO" in states
      assert "FI" in states
      assert "LT" in states
    end

    test "member_state?/1 accurately identifies EU members" do
      assert EURates.member_state?("DE")
      assert EURates.member_state?("FR")
      assert EURates.member_state?("IT")
      assert EURates.member_state?("ES")
      assert EURates.member_state?("GR")

      refute EURates.member_state?("GB")
      refute EURates.member_state?("AE")
      refute EURates.member_state?("US")
      refute EURates.member_state?("IN")
      refute EURates.member_state?(nil)
    end
  end

  describe "EURates presets and provenance mappings" do
    test "presets/1 returns standard rates and shared EU extras" do
      presets = EURates.presets("DE")
      names = Enum.map(presets, &elem(&1, 0))

      assert "Standard 19%" in names
      assert "Reduced 7%" in names
      assert "Zero-rated" in names
      assert "Exempt" in names
      assert "Intra-EU reverse charge" in names
    end

    test "presets/1 reflects latest statutory rates for EE, RO, FI, LT" do
      ee_rates = Enum.map(EURates.presets("EE"), &elem(&1, 0))
      assert "Standard 24%" in ee_rates
      assert "Reduced 13%" in ee_rates
      assert "Reduced 9%" in ee_rates

      ro_rates = Enum.map(EURates.presets("RO"), &elem(&1, 0))
      assert "Standard 21%" in ro_rates
      assert "Reduced 11%" in ro_rates

      fi_rates = Enum.map(EURates.presets("FI"), &elem(&1, 0))
      assert "Standard 25.5%" in fi_rates
      assert "Reduced 13.5%" in fi_rates

      lt_rates = Enum.map(EURates.presets("LT"), &elem(&1, 0))
      assert "Standard 21%" in lt_rates
      assert "Reduced 12%" in lt_rates
    end

    test "rates_with_provenance/1 embeds source and dates on each rate" do
      rates = EURates.rates_with_provenance("FR")
      assert length(rates) > 0

      for rate <- rates do
        assert is_map(rate)
        assert rate.source == EURates.source()
        assert rate.verified_on == EURates.verified_on()
        assert is_binary(rate.name)
        assert is_binary(rate.category)
        assert is_integer(rate.rate_bp)
      end
    end
  end

  describe "Tax integration with EURates" do
    test "Tax.presets/1 resolves EU starter rates via EURates" do
      de_presets = Tax.presets("DE")
      assert de_presets == EURates.presets("DE")

      fr_presets = Tax.presets("FR")
      assert fr_presets == EURates.presets("FR")
    end

    test "Tax.country_name/1 resolves EU country names" do
      assert Tax.country_name("DE") == "Germany"
      assert Tax.country_name("FR") == "France"
      assert Tax.country_name("IT") == "Italy"
      assert Tax.country_name("GR") == "Greece"
    end

    test "Tax.countries/0 includes EU countries alongside non-EU presets" do
      countries = Tax.countries()
      codes = Enum.map(countries, &elem(&1, 0))

      assert "AE" in codes
      assert "GB" in codes
      assert "DE" in codes
      assert "FR" in codes
      assert "ES" in codes
      assert "GR" in codes
    end

    test "Tax.tax_number_valid?/2 validates EU VAT identifiers" do
      assert Tax.tax_number_valid?("DE", "DE123456789")
      assert Tax.tax_number_valid?("FR", "FR12345678901")
      refute Tax.tax_number_valid?("DE", "US123456789")
      refute Tax.tax_number_valid?("DE", "")
    end

    test "Tax.tax_number_valid?/2 validates Greek VAT numbers using EL prefix" do
      assert Tax.tax_number_valid?("GR", "EL094014201")
      assert Tax.tax_number_valid?("EL", "EL094014201")
      refute Tax.tax_number_valid?("GR", "GR094014201")
    end
  end
end
