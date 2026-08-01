defmodule QuantumBilling.HsnFinderTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.HsnFinder

  describe "entries/0" do
    test "has no duplicate codes" do
      codes = Enum.map(HsnFinder.entries(), & &1.code)

      assert codes -- Enum.uniq(codes) == []
    end

    test "every entry's tax split reconciles" do
      for entry <- HsnFinder.entries() do
        assert entry.cgst + entry.sgst == entry.rate,
               "#{entry.code}: cgst + sgst (#{entry.cgst} + #{entry.sgst}) != rate (#{entry.rate})"

        assert entry.igst == entry.rate, "#{entry.code}: igst != rate"
      end
    end

    test "only uses the current post-GST-2.0 slabs" do
      rates = HsnFinder.entries() |> Enum.map(& &1.rate) |> Enum.uniq() |> Enum.sort()

      assert rates == [0, 5, 18, 40]
    end

    test "every entry is dated to the GST 2.0 restructuring" do
      assert Enum.all?(HsnFinder.entries(), &(&1.effective_from == ~D[2025-09-22]))
    end

    test "every entry is typed as either goods (hsn) or a service (sac)" do
      assert Enum.all?(HsnFinder.entries(), &(&1.type in [:hsn, :sac]))
    end
  end

  describe "search_by_keyword/1" do
    test "matches the formal description" do
      results = HsnFinder.search_by_keyword("automatic data processing")

      assert Enum.any?(results, &(&1.code == "8471"))
    end

    test "matches a plain-language keyword alias for formal customs wording" do
      # The gap keywords exist to close: nobody searches "automatic data
      # processing machines" — they search "laptop".
      assert HsnFinder.search_by_keyword("laptop") |> Enum.any?(&(&1.code == "8471"))
      assert HsnFinder.search_by_keyword("computer") |> Enum.any?(&(&1.code == "8471"))
    end

    test "is case-insensitive" do
      assert HsnFinder.search_by_keyword("LAPTOP") == HsnFinder.search_by_keyword("laptop")
    end

    test "restaurant services are 18%, the post-reform rate" do
      # Pre-reform this was widely 5%. Getting this right is the whole point of
      # having verified the current structure rather than assumed it.
      assert [%{code: "9963", rate: 18}] = HsnFinder.search_by_keyword("restaurant")
    end

    test "individual health and life insurance is exempt, not merely reduced" do
      assert [%{rate: 0}] = HsnFinder.search_by_keyword("insurance")
    end

    test "an unmatched query returns an empty list, not an error" do
      assert HsnFinder.search_by_keyword("xyzabc123nonsense") == []
    end

    test "a blank query returns nothing rather than everything" do
      assert HsnFinder.search_by_keyword("") == []
      assert HsnFinder.search_by_keyword("   ") == []
    end
  end

  describe "search_by_code/1" do
    test "matches an exact code" do
      assert [%{code: "8471"}] = HsnFinder.search_by_code("8471")
    end

    test "matches by prefix" do
      results = HsnFinder.search_by_code("84")

      assert results != []
      assert Enum.all?(results, &String.starts_with?(&1.code, "84"))
    end

    test "an unmatched code returns an empty list" do
      assert HsnFinder.search_by_code("00000") == []
    end

    test "a blank query returns nothing" do
      assert HsnFinder.search_by_code("") == []
    end

    test "tolerates stray whitespace" do
      assert HsnFinder.search_by_code(" 8471 ") == HsnFinder.search_by_code("8471")
    end
  end

  describe "get_by_code/1" do
    test "returns the single matching entry" do
      assert %{code: "8471", rate: 18} = HsnFinder.get_by_code("8471")
    end

    test "returns nil for an unknown code" do
      assert HsnFinder.get_by_code("00000") == nil
    end
  end

  describe "categories/0" do
    test "is non-empty and sorted" do
      categories = HsnFinder.categories()

      assert categories != []
      assert categories == Enum.sort(categories)
    end
  end
end
