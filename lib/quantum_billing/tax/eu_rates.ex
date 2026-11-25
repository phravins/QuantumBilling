defmodule QuantumBilling.Tax.EURates do
  @moduledoc """
  Preset VAT rates and official provenance for EU member states.

  Rates are sourced from the European Commission's Taxes in Europe Database
  (TEDB) and provide standard, reduced, super-reduced, and shared EU zero/exempt
  rules with explicit verification dates and official source attribution.
  """

  @source "European Commission Taxes in Europe Database (TEDB)"
  @verified_on "2026-11-24"

  @eu_extras [
    {"Zero-rated", "zero", 0},
    {"Exempt", "exempt", 0},
    {"Intra-EU reverse charge", "reverse_charge", 0}
  ]

  # All 27 European Union Member States with official VAT rates (in basis points)
  @member_states %{
    "AT" =>
      {"Austria",
       [
         {"Standard 20%", "standard", 2000},
         {"Reduced 10%", "reduced", 1000},
         {"Reduced 13%", "reduced", 1300}
       ]},
    "BE" =>
      {"Belgium",
       [
         {"Standard 21%", "standard", 2100},
         {"Reduced 6%", "reduced", 600},
         {"Reduced 12%", "reduced", 1200}
       ]},
    "BG" =>
      {"Bulgaria",
       [
         {"Standard 20%", "standard", 2000},
         {"Reduced 9%", "reduced", 900}
       ]},
    "CY" =>
      {"Cyprus",
       [
         {"Standard 19%", "standard", 1900},
         {"Reduced 9%", "reduced", 900},
         {"Reduced 5%", "reduced", 500}
       ]},
    "CZ" =>
      {"Czechia",
       [
         {"Standard 21%", "standard", 2100},
         {"Reduced 12%", "reduced", 1200}
       ]},
    "DE" =>
      {"Germany",
       [
         {"Standard 19%", "standard", 1900},
         {"Reduced 7%", "reduced", 700}
       ]},
    "DK" =>
      {"Denmark",
       [
         {"Standard 25%", "standard", 2500}
       ]},
    "EE" =>
      {"Estonia",
       [
         {"Standard 24%", "standard", 2400},
         {"Reduced 13%", "reduced", 1300},
         {"Reduced 9%", "reduced", 900}
       ]},
    "ES" =>
      {"Spain",
       [
         {"Standard 21%", "standard", 2100},
         {"Reduced 10%", "reduced", 1000},
         {"Super-reduced 4%", "reduced", 400}
       ]},
    "FI" =>
      {"Finland",
       [
         {"Standard 25.5%", "standard", 2550},
         {"Reduced 13.5%", "reduced", 1350},
         {"Reduced 10%", "reduced", 1000}
       ]},
    "FR" =>
      {"France",
       [
         {"Standard 20%", "standard", 2000},
         {"Reduced 10%", "reduced", 1000},
         {"Reduced 5.5%", "reduced", 550},
         {"Super-reduced 2.1%", "reduced", 210}
       ]},
    "GR" =>
      {"Greece",
       [
         {"Standard 24%", "standard", 2400},
         {"Reduced 13%", "reduced", 1300},
         {"Reduced 6%", "reduced", 600}
       ]},
    "HR" =>
      {"Croatia",
       [
         {"Standard 25%", "standard", 2500},
         {"Reduced 13%", "reduced", 1300},
         {"Reduced 5%", "reduced", 500}
       ]},
    "HU" =>
      {"Hungary",
       [
         {"Standard 27%", "standard", 2700},
         {"Reduced 18%", "reduced", 1800},
         {"Reduced 5%", "reduced", 500}
       ]},
    "IE" =>
      {"Ireland",
       [
         {"Standard 23%", "standard", 2300},
         {"Reduced 13.5%", "reduced", 1350},
         {"Reduced 9%", "reduced", 900},
         {"Super-reduced 4.8%", "reduced", 480}
       ]},
    "IT" =>
      {"Italy",
       [
         {"Standard 22%", "standard", 2200},
         {"Reduced 10%", "reduced", 1000},
         {"Reduced 5%", "reduced", 500},
         {"Super-reduced 4%", "reduced", 400}
       ]},
    "LT" =>
      {"Lithuania",
       [
         {"Standard 21%", "standard", 2100},
         {"Reduced 12%", "reduced", 1200},
         {"Reduced 5%", "reduced", 500}
       ]},
    "LU" =>
      {"Luxembourg",
       [
         {"Standard 17%", "standard", 1700},
         {"Reduced 14%", "reduced", 1400},
         {"Reduced 8%", "reduced", 800},
         {"Super-reduced 3%", "reduced", 300}
       ]},
    "LV" =>
      {"Latvia",
       [
         {"Standard 21%", "standard", 2100},
         {"Reduced 12%", "reduced", 1200},
         {"Reduced 5%", "reduced", 500}
       ]},
    "MT" =>
      {"Malta",
       [
         {"Standard 18%", "standard", 1800},
         {"Reduced 7%", "reduced", 700},
         {"Reduced 5%", "reduced", 500}
       ]},
    "NL" =>
      {"Netherlands",
       [
         {"Standard 21%", "standard", 2100},
         {"Reduced 9%", "reduced", 900}
       ]},
    "PL" =>
      {"Poland",
       [
         {"Standard 23%", "standard", 2300},
         {"Reduced 8%", "reduced", 800},
         {"Reduced 5%", "reduced", 500}
       ]},
    "PT" =>
      {"Portugal",
       [
         {"Standard 23%", "standard", 2300},
         {"Reduced 13%", "reduced", 1300},
         {"Reduced 6%", "reduced", 600}
       ]},
    "RO" =>
      {"Romania",
       [
         {"Standard 21%", "standard", 2100},
         {"Reduced 11%", "reduced", 1100}
       ]},
    "SE" =>
      {"Sweden",
       [
         {"Standard 25%", "standard", 2500},
         {"Reduced 12%", "reduced", 1200},
         {"Reduced 6%", "reduced", 600}
       ]},
    "SI" =>
      {"Slovenia",
       [
         {"Standard 22%", "standard", 2200},
         {"Reduced 9.5%", "reduced", 950},
         {"Reduced 5%", "reduced", 500}
       ]},
    "SK" =>
      {"Slovakia",
       [
         {"Standard 23%", "standard", 2300},
         {"Reduced 19%", "reduced", 1900},
         {"Reduced 5%", "reduced", 500}
       ]}
  }

  @doc "The source of the VAT rate data."
  def source, do: @source

  @doc "Date the rates were verified against the official source."
  def verified_on, do: @verified_on

  @doc "Shared EU tax exemptions, zero-rates, and reverse charge rules."
  def eu_extras, do: @eu_extras

  @doc "List of all EU ISO-2 country codes."
  def member_states, do: Map.keys(@member_states) |> Enum.sort()

  @doc "Returns true if country code is an EU member state."
  def member_state?(code) when is_binary(code), do: Map.has_key?(@member_states, code)
  def member_state?(_code), do: false

  @doc "The country name for an EU member state code."
  def country_name(code) when is_binary(code) do
    case Map.get(@member_states, code) do
      {name, _rates} -> name
      nil -> nil
    end
  end

  @doc "All EU countries as `{code, name}` tuples."
  def countries do
    @member_states
    |> Enum.map(fn {code, {name, _rates}} -> {code, name} end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  @doc """
  Starter preset rates for an EU country code as `{name, category, rate_bp}` tuples.
  Appends shared EU zero-rated, exempt, and reverse charge entries.
  """
  def presets(code) when is_binary(code) do
    case Map.get(@member_states, code) do
      {_name, rates} -> rates ++ @eu_extras
      nil -> []
    end
  end

  @doc """
  Preset rates for an EU country code with full provenance metadata.
  """
  def rates_with_provenance(code) when is_binary(code) do
    case Map.get(@member_states, code) do
      {_name, rates} ->
        Enum.map(rates ++ @eu_extras, fn {name, category, rate_bp} ->
          %{
            name: name,
            category: category,
            rate_bp: rate_bp,
            source: @source,
            verified_on: @verified_on
          }
        end)

      nil ->
        []
    end
  end
end
