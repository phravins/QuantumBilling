defmodule QuantumBilling.HsnSuggestTest do
  @moduledoc """
  Issue #100: `HsnFinder.suggest/2` ranking. The business's own history first,
  then the catalogue; word by word; nothing for a description with no match.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.HsnFinder
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem

  defp billed(description, code, rate, invoice_attrs \\ %{}) do
    invoice =
      Repo.insert!(
        struct(
          %Invoice{
            invoice_number: "INV-#{System.unique_integer([:positive])}",
            invoice_date: ~D[2026-11-01],
            client_name: "Earlier Client"
          },
          invoice_attrs
        )
      )

    Repo.insert!(%InvoiceItem{
      invoice_id: invoice.id,
      description: description,
      hsn_sac: code,
      quantity: 1,
      unit: "Nos",
      rate: 100_000,
      tax_rate: rate,
      amount: 100_000,
      position: 0
    })
  end

  defp codes(suggestions), do: Enum.map(suggestions, & &1.code)

  describe "catalogue" do
    test "matches word by word, plurals included" do
      assert "9401" in codes(HsnFinder.suggest("Office chair", history: false))
      assert "9401" in codes(HsnFinder.suggest("Chairs", history: false))
      assert "8471" in codes(HsnFinder.suggest("Laptop repair", history: false))
    end

    test "does not match a word inside another one" do
      # "desk" is not "desktop".
      refute "8471" in codes(HsnFinder.suggest("Wooden desk", history: false))
    end

    test "carries the code's type and rate" do
      assert [%{code: "998231", type: :sac, rate: 18, source: :catalogue} | _] =
               HsnFinder.suggest("Legal consultation", history: false)
    end

    test "suggests nothing when nothing matches, or the words say nothing" do
      assert HsnFinder.suggest("Zxqv widget") == []
      assert HsnFinder.suggest("and the of") == []
      assert HsnFinder.suggest("") == []
    end

    test "codes are suggested by prefix" do
      assert "9401" in codes(HsnFinder.suggest_code("94"))
      assert Enum.all?(HsnFinder.suggest_code("99"), &(&1.type == :sac))
    end
  end

  describe "history" do
    test "the business's own lines come before the catalogue" do
      billed("Ergonomic office chair", "940130", 18)

      assert [%{code: "940130", source: :history, type: :hsn} | rest] =
               HsnFinder.suggest("Office chair")

      assert "9401" in codes(rest)
    end

    test "a code is listed once, by its best source" do
      billed("Plastic chair", "9401", 18)

      suggestions = HsnFinder.suggest("Chair")

      assert Enum.count(suggestions, &(&1.code == "9401")) == 1
      assert %{source: :history} = Enum.find(suggestions, &(&1.code == "9401"))
    end

    test "the more often a code was used, the higher it ranks" do
      billed("Steel chair", "940171", 18)
      billed("Steel chair", "940179", 18)
      billed("Steel chair", "940179", 18)

      assert ["940179", "940171" | _] = codes(HsnFinder.suggest("Steel chair"))
    end

    test "VAT invoices and binned invoices are left out" do
      billed("Folding chair", "940120", 5, %{tax_regime: "vat"})
      billed("Folding chair", "940110", 18, %{deleted_at: DateTime.utc_now(:second)})

      refute "940120" in codes(HsnFinder.suggest("Folding chair"))
      refute "940110" in codes(HsnFinder.suggest("Folding chair"))
    end

    test "is capped at five suggestions" do
      for n <- 1..8, do: billed("Garden chair #{n}", "94010#{n}", 18)

      assert length(HsnFinder.suggest("Garden chair")) == 5
    end

    test "a past line that shares no whole word is not suggested" do
      # "milk" is inside "milkshake", but a milkshake mixer is not milk.
      billed("Milkshake mixer", "8509", 18)

      suggestions = HsnFinder.suggest("Milk")

      refute "8509" in codes(suggestions)
      assert [%{code: "0401", source: :catalogue} | _] = suggestions
    end

    test "a singular finds a plural line, and a plural a singular one" do
      billed("Office chair", "940130", 18)
      billed("AA batteries", "850610", 18)

      assert "940130" in codes(HsnFinder.suggest("Chairs"))
      assert "850610" in codes(HsnFinder.suggest("Battery"))
      assert "850610" in codes(HsnFinder.suggest("Batteries"))
    end

    test "a short word still finds its own lines" do
      billed("LPG gas refill", "271111", 5)
      billed("Garden hose", "391740", 18)

      suggestions = HsnFinder.suggest("Gas")

      assert "271111" in codes(suggestions)
      refute "391740" in codes(suggestions)
    end
  end
end
