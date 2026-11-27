defmodule QuantumBilling.HsnFinder do
  @moduledoc """
  A curated list of common HSN (goods) and SAC (services) codes and their GST rates.

  About 45 entries, not the full ~22,000-code master. Rates follow the GST 2.0
  slabs (0/5/18/40) from 22 September 2025. Categories with conditional rates
  (hotels, GTA, works contracts, real estate) are left out.
  """

  @gst_2_0_date ~D[2025-09-22]
  @source "GST 2.0 — Notification No. 9/2025-Integrated Tax (Rate)"

  @entries [
    # ── 0% — exempt ────────────────────────────────────────────────────────
    %{
      code: "9971",
      type: :sac,
      description: "Individual life insurance and health insurance services",
      keywords: ~w(insurance life health policy premium),
      rate: 0,
      category: "Insurance"
    },
    %{
      code: "9993",
      type: :sac,
      description: "Human health and social care services",
      keywords: ~w(hospital doctor clinic healthcare medical treatment),
      rate: 0,
      category: "Healthcare"
    },
    %{
      code: "9992",
      type: :sac,
      description: "Education services",
      keywords: ~w(school college tuition education training course),
      rate: 0,
      category: "Education"
    },
    %{
      code: "0401",
      type: :hsn,
      description: "Milk and cream, not concentrated nor containing added sugar",
      keywords: ~w(milk dairy fresh),
      rate: 0,
      category: "Food & Agriculture"
    },
    %{
      code: "0701",
      type: :hsn,
      description: "Potatoes, fresh or chilled",
      keywords: ~w(potato vegetable fresh produce),
      rate: 0,
      category: "Food & Agriculture"
    },
    %{
      code: "1001",
      type: :hsn,
      description: "Wheat and meslin, unbranded",
      keywords: ~w(wheat grain food staple unbranded),
      rate: 0,
      category: "Food & Agriculture"
    },

    # ── 5% ───────────────────────────────────────────────────────────────────
    %{
      code: "3004",
      type: :hsn,
      description: "Medicaments (excluding goods of heading 3002, 3005 or 3006)",
      keywords: ~w(medicine drug pharmaceutical tablet capsule),
      rate: 5,
      category: "Pharmaceuticals"
    },
    %{
      code: "6403",
      type: :hsn,
      description:
        "Footwear with outer soles of rubber, plastics, leather or composition leather",
      keywords: ~w(footwear shoes sandals leather),
      rate: 5,
      category: "Apparel & Footwear"
    },
    %{
      code: "5208",
      type: :hsn,
      description: "Woven fabrics of cotton, containing 85% or more by weight of cotton",
      keywords: ~w(cotton fabric textile cloth woven),
      rate: 5,
      category: "Textiles"
    },
    %{
      code: "5205",
      type: :hsn,
      description: "Cotton yarn (other than sewing thread)",
      keywords: ~w(cotton yarn thread textile),
      rate: 5,
      category: "Textiles"
    },
    %{
      code: "6109",
      type: :hsn,
      description: "T-shirts, singlets and other vests, knitted or crocheted",
      keywords: ~w(tshirt apparel clothing garment vest),
      rate: 5,
      category: "Apparel & Footwear"
    },
    %{
      code: "1905",
      type: :hsn,
      description: "Bread, pastry, cakes, biscuits and other bakers' wares",
      keywords: ~w(bread biscuit bakery food packaged),
      rate: 5,
      category: "Food & Agriculture"
    },
    %{
      code: "8703",
      type: :hsn,
      description: "Electrically operated vehicles, including three-wheeled electric vehicles",
      keywords: ~w(electric vehicle ev car),
      rate: 5,
      category: "Automobiles"
    },
    %{
      code: "8201",
      type: :hsn,
      description: "Agricultural hand tools — spades, shovels, hoes, rakes",
      keywords: ~w(agriculture farming tool equipment),
      rate: 5,
      category: "Food & Agriculture"
    },

    # ── 18% ──────────────────────────────────────────────────────────────────
    %{
      code: "8471",
      type: :hsn,
      description:
        "Automatic data processing machines and units thereof; magnetic or optical " <>
          "readers, machines for transcribing data onto data media in coded form and " <>
          "machines for processing such data",
      keywords: ~w(computer laptop pc desktop server data-processing),
      rate: 18,
      category: "Electronics"
    },
    %{
      code: "8517",
      type: :hsn,
      description: "Telephones for cellular networks or for other wireless networks",
      keywords: ~w(mobile phone smartphone cellular handset),
      rate: 18,
      category: "Electronics"
    },
    %{
      code: "8528",
      type: :hsn,
      description: "Television reception apparatus and monitors",
      keywords: ~w(television tv monitor screen display),
      rate: 18,
      category: "Electronics"
    },
    %{
      code: "8450",
      type: :hsn,
      description: "Household or laundry-type washing machines",
      keywords: ~w(washing machine laundry appliance),
      rate: 18,
      category: "Electronics"
    },
    %{
      code: "8415",
      type: :hsn,
      description: "Air conditioning machines",
      keywords: ~w(air conditioner ac cooling appliance),
      rate: 18,
      category: "Electronics"
    },
    %{
      code: "2523",
      type: :hsn,
      description: "Portland cement, aluminous cement, slag cement",
      keywords: ~w(cement construction building material),
      rate: 18,
      category: "Construction Materials"
    },
    %{
      code: "9401",
      type: :hsn,
      description: "Seats and furniture (excluding medical, dental or barber furniture)",
      keywords: ~w(furniture chair seat table),
      rate: 18,
      category: "Furniture"
    },
    %{
      code: "9963",
      type: :sac,
      description: "Restaurant services, including takeaway and delivery",
      keywords: ~w(restaurant food dining takeaway delivery cafe),
      rate: 18,
      category: "Hospitality"
    },
    %{
      code: "998313",
      type: :sac,
      description: "Information technology (IT) consulting and support services",
      keywords: ~w(it software consulting technology support development),
      rate: 18,
      category: "Professional Services"
    },
    %{
      code: "998311",
      type: :sac,
      description: "Management consulting and management services",
      keywords: ~w(consulting management advisory business),
      rate: 18,
      category: "Professional Services"
    },
    %{
      code: "998231",
      type: :sac,
      description: "Legal advisory and representation services",
      keywords: ~w(legal lawyer advocate attorney law),
      rate: 18,
      category: "Professional Services"
    },
    %{
      code: "998221",
      type: :sac,
      description: "Accounting, auditing and bookkeeping services",
      keywords: ~w(accounting audit bookkeeping tax-filing ca),
      rate: 18,
      category: "Professional Services"
    },
    %{
      code: "998361",
      type: :sac,
      description: "Advertising services and provision of advertising space or time",
      keywords: ~w(advertising marketing promotion media),
      rate: 18,
      category: "Professional Services"
    },
    %{
      code: "996511",
      type: :sac,
      description: "Road transport services of goods (standard, non-GTA)",
      keywords: ~w(transport logistics freight goods road shipping),
      rate: 18,
      category: "Transport & Logistics"
    },
    %{
      code: "997212",
      type: :sac,
      description: "Rental or leasing of commercial immovable property",
      keywords: ~w(rent lease commercial property office),
      rate: 18,
      category: "Real Estate"
    },
    %{
      code: "9954",
      type: :sac,
      description: "General construction services of buildings",
      keywords: ~w(construction building contractor works),
      rate: 18,
      category: "Construction Materials"
    },
    %{
      code: "998599",
      type: :sac,
      description: "Business support services not elsewhere classified",
      keywords: ~w(business support services outsourcing back-office),
      rate: 18,
      category: "Professional Services"
    },

    # ── 40% — sin / luxury ─────────────────────────────────────────────────
    %{
      code: "2202",
      type: :hsn,
      description: "Waters, including mineral and aerated waters, containing added sugar",
      keywords: ~w(aerated beverage soft-drink soda carbonated),
      rate: 40,
      category: "Sin Goods"
    },
    %{
      code: "2402",
      type: :hsn,
      description: "Cigars, cheroots, cigarillos and cigarettes of tobacco",
      keywords: ~w(cigarette tobacco cigar smoking),
      rate: 40,
      category: "Sin Goods"
    },
    %{
      code: "2403",
      type: :hsn,
      description: "Other manufactured tobacco and tobacco substitutes; pan masala",
      keywords: ~w(tobacco pan-masala gutkha chewing),
      rate: 40,
      category: "Sin Goods"
    },
    %{
      code: "8711",
      type: :hsn,
      description: "Motorcycles with engine capacity exceeding 350cc",
      keywords: ~w(motorcycle bike premium high-capacity),
      rate: 40,
      category: "Automobiles"
    }
  ]

  @doc "Every entry in full display shape, with the tax split, effective date and source added."
  def entries, do: Enum.map(@entries, &resolve/1)

  defp resolve(entry) do
    Map.merge(entry, %{
      igst: entry.rate,
      cgst: div(entry.rate, 2),
      sgst: entry.rate - div(entry.rate, 2),
      cess: 0,
      effective_from: @gst_2_0_date,
      source: @source
    })
  end

  @doc """
  Searches descriptions and keyword aliases, case-insensitively (e.g. "laptop").
  """
  def search_by_keyword(query) when is_binary(query) do
    needle = query |> String.trim() |> String.downcase()

    if needle == "" do
      []
    else
      entries()
      |> Enum.filter(fn entry ->
        String.contains?(String.downcase(entry.description), needle) or
          Enum.any?(entry.keywords, &String.contains?(&1, needle))
      end)
    end
  end

  @doc """
  Matches a code exactly or by prefix, so "84" finds every heading under
  Chapter 84 and "8471" finds the exact one.
  """
  def search_by_code(query) when is_binary(query) do
    needle = query |> String.trim() |> String.replace(~r/\s/, "")

    if needle == "" do
      []
    else
      Enum.filter(entries(), &String.starts_with?(&1.code, needle))
    end
  end

  @doc "The single entry for an exact code, or `nil`."
  def get_by_code(code) do
    Enum.find(entries(), &(&1.code == code))
  end

  @doc "The date the current rate structure took effect."
  def gst_2_0_date, do: @gst_2_0_date

  # Words too common to say anything about the goods or service.
  @stop_words ~w(and the for with from per of to in on a an by or our your new
                 item items service services charges charge fee fees)

  # The most suggestions a line shows.
  @suggestion_limit 5

  @doc """
  HSN/SAC suggestions for a line's description, best first, at most
  #{@suggestion_limit}: `%{code, description, rate, source}`, where `source`
  is `:history` (this business has billed a line like it before, with that
  code and rate) or `:catalogue` (this module's list).

  Words are matched one by one, so "Laptop repair" finds both laptops and
  repairs. The business's own history comes first: it is what the business
  has actually billed. A code appears once, under its best source. A
  description with no usable word suggests nothing.

  `opts` takes `:limit` and `:history` (false skips the database, for a
  business without one selected).
  """
  def suggest(description, opts \\ [])

  def suggest(description, opts) when is_binary(description) do
    words = words(description)
    limit = Keyword.get(opts, :limit, @suggestion_limit)

    if words == [] do
      []
    else
      history = if Keyword.get(opts, :history, true), do: history(words), else: []

      (history ++ catalogue(words))
      |> Enum.uniq_by(& &1.code)
      |> Enum.take(limit)
    end
  end

  def suggest(_description, _opts), do: []

  defp words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stop_words))
    |> Enum.uniq()
  end

  # Entries whose description or keywords share a word, most shared first.
  defp catalogue(words) do
    entries()
    |> Enum.map(fn entry ->
      vocabulary = words(entry.description) ++ entry.keywords
      {entry, Enum.count(words, &matches?(&1, vocabulary))}
    end)
    |> Enum.filter(fn {_entry, score} -> score > 0 end)
    |> Enum.sort_by(fn {entry, score} -> {-score, entry.code} end)
    |> Enum.map(fn {entry, _score} -> from_entry(entry) end)
  end

  defp from_entry(entry) do
    %{
      code: entry.code,
      type: entry.type,
      description: entry.description,
      rate: entry.rate,
      source: :catalogue
    }
  end

  @doc """
  Suggestions for a code being typed: catalogue entries under that prefix
  ("94" finds 9401, 9403...), best first, at most #{@suggestion_limit}.
  """
  def suggest_code(digits, opts \\ []) when is_binary(digits) do
    digits
    |> search_by_code()
    |> Enum.sort_by(& &1.code)
    |> Enum.take(Keyword.get(opts, :limit, @suggestion_limit))
    |> Enum.map(&from_entry/1)
  end

  @doc "HSN (goods) or SAC (services): a SAC starts with 99."
  def code_type("99" <> _rest), do: :sac
  def code_type(_code), do: :hsn

  # The same word, or its plural: "chairs" finds "chair", "desk" does not
  # find "desktop".
  defp matches?(word, vocabulary), do: Enum.any?(vocabulary, &(singular(&1) == singular(word)))

  defp singular(word) do
    cond do
      String.ends_with?(word, "ies") and String.length(word) > 4 ->
        String.slice(word, 0..-4//1) <> "y"

      String.ends_with?(word, ["ches", "shes", "sses", "xes"]) ->
        String.slice(word, 0..-3//1)

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.slice(word, 0..-2//1)

      true ->
        word
    end
  end

  # This business's own lines (invoices and quotations not in the Bin) that
  # share a word with the description (singular or plural, as `matches?/2`)
  # and carry an HSN/SAC: grouped by code and rate, most shared words first,
  # then most used. SQL only narrows the lines ("milk" is also in
  # "milkshake"); `matches?/2` decides.
  defp history(words) do
    import Ecto.Query, only: [from: 2]

    patterns =
      words
      |> Enum.flat_map(&like_forms/1)
      |> Enum.uniq()
      |> Enum.map(&("%" <> escape_like(&1) <> "%"))

    invoice_lines =
      from i in QuantumBilling.Invoices.InvoiceItem,
        join: d in ^QuantumBilling.Invoices.Invoice.kept(),
        on: d.id == i.invoice_id,
        where: d.tax_regime == "gst",
        where: not is_nil(i.hsn_sac) and i.hsn_sac != "",
        where: fragment("lower(?) LIKE ANY(?)", i.description, ^patterns),
        order_by: [desc: i.id],
        limit: 200,
        select: %{description: i.description, code: i.hsn_sac, rate: i.tax_rate}

    quotation_lines =
      from i in QuantumBilling.Quotations.QuotationItem,
        join: d in ^QuantumBilling.Quotations.Quotation.kept(),
        on: d.id == i.quotation_id,
        where: d.tax_regime == "gst",
        where: not is_nil(i.hsn_sac) and i.hsn_sac != "",
        where: fragment("lower(?) LIKE ANY(?)", i.description, ^patterns),
        order_by: [desc: i.id],
        limit: 200,
        select: %{description: i.description, code: i.hsn_sac, rate: i.tax_rate}

    (QuantumBilling.Repo.all(invoice_lines) ++ QuantumBilling.Repo.all(quotation_lines))
    |> Enum.group_by(&{String.trim(&1.code), &1.rate})
    |> Enum.map(fn {{code, rate}, lines} ->
      best =
        Enum.max_by(
          lines,
          &Enum.count(words, fn word -> matches?(word, words(&1.description)) end)
        )

      score = Enum.count(words, &matches?(&1, words(best.description)))

      suggestion = %{
        code: code,
        type: code_type(code),
        description: best.description,
        rate: rate,
        source: :history
      }

      {suggestion, score, length(lines)}
    end)
    |> Enum.filter(fn {_suggestion, score, _uses} -> score > 0 end)
    |> Enum.sort_by(fn {suggestion, score, uses} -> {-score, -uses, suggestion.code} end)
    |> Enum.map(&elem(&1, 0))
  end

  # Text a stored line holds when it has `word`, its singular or its plural.
  # The singular is inside most plurals ("chair" in "chairs", "box" in
  # "boxes"); "batteries" does not hold "battery", so it gets a pattern of
  # its own. A three-letter word keeps itself: "gas" as "ga" would match
  # nearly every line and fill the row limit.
  defp like_forms(word) do
    singular = singular(word)

    cond do
      String.length(singular) < 3 ->
        [word]

      Regex.match?(~r/[^aeiou]y\z/, singular) ->
        [singular, String.slice(singular, 0..-2//1) <> "ies"]

      true ->
        [singular]
    end
  end

  defp escape_like(word), do: String.replace(word, ~r/[\\%_]/, "\\\\\\0")
end
