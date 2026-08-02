defmodule QuantumBilling.HsnFinder do
  @moduledoc """
  A curated reference of common HSN (goods) and SAC (services) codes and their
  current GST rates.

  Held as module attributes, the same way `QuantumBilling.Compliance` holds the
  statutory filing calendar — this is shared reference data with no per-tenant
  variation, not something to CRUD, and not fabricated the way the app's old
  sample invoices and clients once were.

  ## Why ~45 entries, not the real ~22,000

  The actual government HSN/SAC master runs to roughly twenty-two thousand
  codes, and nothing available here can reliably import that. This is a
  curated set of commonly searched codes instead, correctly rated and clearly
  presented as a starting point — the UI's empty state exists specifically to
  send a miss to the real official source rather than implying the tool is
  broken.

  ## Why these rates, specifically

  GST was restructured on 22 September 2025 ("GST 2.0"): the previous five-tier
  0/5/12/18/28 slab structure collapsed to essentially 0/5/18/40, with 12% and
  28% retired and items redistributed. Every rate below reflects that current
  structure, verified against multiple current tax-compliance sources rather
  than assumed — training-data recall alone would have gotten restaurant
  services (now 18%, not the pre-reform 5%) and individual life/health
  insurance (now exempt, not merely reduced) wrong.

  Deliberately excluded: categories whose real rate is conditional rather than
  flat — hotel accommodation (varies by declared tariff), GTA road transport
  (varies by the carrier's ITC election), works contracts and real estate
  (vary by contract type). Asserting one number for those would be actively
  wrong for a real fraction of cases; leaving them out is more honest than
  guessing.
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

  @doc """
  Every entry, resolved to its full display shape: the tax split, effective
  date and source added once here rather than duplicated on every literal
  above.
  """
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
  Searches descriptions and keyword aliases, case-insensitively.

  Matches on a plain-language term ("laptop") as well as the formal customs
  wording ("automatic data processing machines") the entry itself carries —
  that gap is exactly what `keywords` on each entry exists to close.
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

  @doc "Every category represented in the curated set, for display grouping."
  def categories do
    @entries |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()
  end

  @doc "The date the current rate structure took effect."
  def gst_2_0_date, do: @gst_2_0_date
end
