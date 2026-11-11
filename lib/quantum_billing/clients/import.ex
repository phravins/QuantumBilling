defmodule QuantumBilling.Clients.Import do
  @moduledoc """
  Turns a spreadsheet of clients exported from another application into
  client attributes, and sorts each row into ready, needs fixing, or already
  exists.

  Columns are matched to client fields by their header (`suggest_mapping/2`),
  which the person can then change. Values are tidied the way people type
  them elsewhere: "+91 98765-43210", "tamil nadu", "Net 30", "₹1,25,000".
  Every row is then checked with the same changeset as the client form, so an
  imported client is exactly as valid as one typed in.
  """

  import Ecto.Query, only: [from: 2]

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CustomFields
  alias QuantumBilling.EWayBills.EWayBillForm
  alias QuantumBilling.Repo

  @custom_prefix "custom:"

  # {target, label, header aliases}. Aliases are compared after `normalize/1`.
  @fields [
    {"name", "Client name",
     ~w(name client customer company party business account vendor) ++
       [
         "client name",
         "customer name",
         "company name",
         "party name",
         "business name",
         "account name",
         "organisation",
         "organization",
         "organisation name",
         "organization name",
         "ledger name",
         "vendor name"
       ]},
    {"display_name", "Display name", ["display name", "short name", "nickname"]},
    {"legal_name", "Legal name", ["legal name", "registered name", "trade name"]},
    {"client_type", "Client type",
     [
       "client type",
       "customer type",
       "gst treatment",
       "gst registration type",
       "registration type",
       "gst type",
       "tax treatment",
       "type"
     ]},
    {"gstin", "GSTIN",
     [
       "gstin",
       "gst",
       "gst no",
       "gst number",
       "gstin uin",
       "gstin number",
       "gst in",
       "gst id",
       "gstin no"
     ]},
    {"pan", "PAN", ["pan", "pan no", "pan number", "income tax pan"]},
    {"tax_number", "Tax number",
     [
       "tax number",
       "vat",
       "vat no",
       "vat number",
       "vat id",
       "trn",
       "tax id",
       "tax no",
       "tax registration number",
       "vat registration number",
       "tin"
     ]},
    {"country", "Country", ["country", "country code", "country iso", "nation"]},
    {"email", "Email",
     [
       "email",
       "e mail",
       "email address",
       "email id",
       "mail",
       "mail id",
       "e mail address",
       "contact email"
     ]},
    {"phone_country_code", "Phone country code",
     ["phone country code", "dial code", "phone code", "isd code", "isd", "calling code"]},
    {"phone", "Phone",
     [
       "phone",
       "mobile",
       "mobile no",
       "mobile number",
       "phone no",
       "phone number",
       "contact",
       "contact no",
       "contact number",
       "telephone",
       "tel",
       "cell",
       "work phone",
       "whatsapp"
     ]},
    {"billing_line1", "Address line 1",
     [
       "address",
       "address line 1",
       "address 1",
       "address1",
       "street",
       "street address",
       "street 1",
       "billing address",
       "billing address line 1",
       "billing street",
       "billing address 1",
       "line 1",
       "building"
     ]},
    {"billing_line2", "Address line 2",
     [
       "address line 2",
       "address 2",
       "address2",
       "street 2",
       "billing address line 2",
       "billing street 2",
       "billing address 2",
       "line 2",
       "area",
       "locality",
       "landmark"
     ]},
    {"billing_city", "City", ["city", "town", "billing city", "city town", "district"]},
    {"billing_state", "State",
     [
       "state",
       "billing state",
       "place of supply",
       "state name",
       "province",
       "region",
       "state province",
       "state code"
     ]},
    {"billing_pin", "PIN / postal code",
     [
       "pin",
       "pincode",
       "pin code",
       "postal code",
       "postcode",
       "post code",
       "zip",
       "zip code",
       "zipcode",
       "billing pin",
       "billing zip",
       "billing postal code",
       "billing code"
     ]},
    {"business_type", "Business type",
     ["business type", "constitution", "constitution of business", "entity type"]},
    {"category", "Category", ["category", "client category", "party type", "group"]},
    {"payment_terms_days", "Payment terms (days)",
     [
       "payment terms",
       "payment terms days",
       "terms",
       "credit days",
       "credit period",
       "due days",
       "payment days"
     ]},
    {"credit_limit", "Credit limit", ["credit limit", "credit limit amount"]},
    {"opening_balance", "Opening balance",
     ["opening balance", "opening balance amount", "balance", "receivable opening balance"]},
    {"notes", "Notes",
     ["notes", "note", "remarks", "remark", "comments", "comment", "description", "memo"]},
    {"status", "Status", ["status", "client status", "active"]}
  ]

  @labels Map.new(@fields, fn {target, label, _aliases} -> {target, label} end)

  @required %{
    "gst" => ~w(name phone billing_line1 billing_city billing_state billing_pin),
    "vat" => ~w(name phone country billing_line1 billing_city)
  }

  @client_type_synonyms %{
    "registered" => "Registered Business",
    "regular" => "Registered Business",
    "b2b" => "Registered Business",
    "business gst" => "Registered Business",
    "registered regular" => "Registered Business",
    "registered business regular" => "Registered Business",
    "gst registered" => "Registered Business",
    "composition" => "Composition Scheme",
    "registered business composition" => "Composition Scheme",
    "registered composition" => "Composition Scheme",
    "sez" => "SEZ Unit",
    "special economic zone" => "SEZ Unit",
    "sez developer" => "SEZ Unit",
    "unregistered business" => "Unregistered",
    "business none" => "Unregistered",
    "not registered" => "Unregistered",
    "urp" => "Unregistered",
    "export" => "Overseas",
    "foreign" => "Overseas",
    "international" => "Overseas",
    "individual" => "Consumer",
    "b2c" => "Consumer",
    "retail" => "Consumer",
    "customer" => "Consumer"
  }

  @country_names %{
    "INDIA" => "IN",
    "UNITED STATES" => "US",
    "UNITED STATES OF AMERICA" => "US",
    "USA" => "US",
    "CANADA" => "CA",
    "UNITED KINGDOM" => "GB",
    "UK" => "GB",
    "GREAT BRITAIN" => "GB",
    "ENGLAND" => "GB",
    "AUSTRALIA" => "AU",
    "SINGAPORE" => "SG",
    "UNITED ARAB EMIRATES" => "AE",
    "UAE" => "AE",
    "SAUDI ARABIA" => "SA",
    "KSA" => "SA",
    "BAHRAIN" => "BH",
    "OMAN" => "OM",
    "QATAR" => "QA",
    "KUWAIT" => "KW",
    "IRELAND" => "IE",
    "GERMANY" => "DE",
    "FRANCE" => "FR",
    "SPAIN" => "ES",
    "ITALY" => "IT",
    "NETHERLANDS" => "NL",
    "BELGIUM" => "BE"
  }

  @dial_codes %{
    "IN" => "+91",
    "US" => "+1",
    "CA" => "+1",
    "GB" => "+44",
    "AU" => "+61",
    "SG" => "+65",
    "AE" => "+971",
    "SA" => "+966",
    "BH" => "+973",
    "OM" => "+968",
    "QA" => "+974",
    "KW" => "+965",
    "IE" => "+353",
    "DE" => "+49",
    "FR" => "+33",
    "ES" => "+34",
    "IT" => "+39",
    "NL" => "+31",
    "BE" => "+32"
  }

  @type row :: %{
          row: pos_integer,
          name: String.t(),
          phone: String.t() | nil,
          status: :ready | :invalid | :duplicate,
          errors: [String.t()],
          attrs: map
        }

  # ── Fields ─────────────────────────────────────────────────────────────────

  @doc """
  The fields a column can fill, as `{group, [{label, target}]}` for a select,
  with the business's active custom fields last.
  """
  def field_options(definitions) do
    standard = for {target, label, _aliases} <- @fields, do: {label, target}
    custom = for d <- definitions, do: {d.label, @custom_prefix <> d.key}

    if custom == [],
      do: [{"Client fields", standard}],
      else: [{"Client fields", standard}, {"Custom fields", custom}]
  end

  @doc "A target's label, for messages."
  def label(@custom_prefix <> key, definitions) do
    case Enum.find(definitions, &(&1.key == key)) do
      nil -> key
      definition -> definition.label
    end
  end

  def label(target, _definitions), do: Map.get(@labels, target, target)

  @doc "The fields every row needs, by regime (`\"gst\"` or `\"vat\"`)."
  def required_targets(regime), do: Map.get(@required, regime, @required["gst"])

  @doc "The required fields (plus required custom fields) as labels, for the upload page."
  def required_labels(regime, definitions) do
    standard = Enum.map(required_targets(regime), &label(&1, definitions))
    custom = for d <- definitions, d.required and d.type != "boolean", do: d.label
    standard ++ custom
  end

  @doc """
  Matches headers to fields by name. Returns `%{"0" => "name", "1" => "", ...}`
  keyed by column index; `""` means the column is not imported. A field is
  given to the first column that matches it.
  """
  def suggest_mapping(headers, definitions) do
    lookup = alias_lookup(definitions)

    {mapping, _used} =
      headers
      |> Enum.with_index()
      |> Enum.reduce({%{}, MapSet.new()}, fn {header, index}, {mapping, used} ->
        target =
          header
          |> header_candidates()
          |> Enum.find_value(fn candidate ->
            case Map.get(lookup, candidate) do
              nil -> nil
              target -> if MapSet.member?(used, target), do: nil, else: target
            end
          end)

        if target,
          do: {Map.put(mapping, to_string(index), target), MapSet.put(used, target)},
          else: {Map.put(mapping, to_string(index), ""), used}
      end)

    mapping
  end

  defp alias_lookup(definitions) do
    custom =
      Enum.flat_map(definitions, fn d ->
        target = @custom_prefix <> d.key
        [{normalize(d.label), target}, {normalize(d.key), target}]
      end)

    standard =
      for {target, label, aliases} <- @fields, name <- [label | aliases] do
        {normalize(name), target}
      end

    # Custom fields win: a business that added "Region" means its own field.
    Map.new(standard ++ custom)
  end

  # "Billing Address" also tries "address"; "Customer Email" also tries "email".
  defp header_candidates(header) do
    normalized = normalize(header)

    stripped =
      Regex.replace(~r/^(billing|client|customer|party|primary|company) /, normalized, "")

    Enum.uniq([normalized, stripped])
  end

  @doc false
  def normalize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  @doc """
  Checks a mapping: every required field is given a column and no field is
  given two. Returns `:ok` or `{:error, [message]}`.
  """
  def validate_mapping(mapping, regime, definitions) do
    targets = mapping |> Map.values() |> Enum.reject(&(&1 in ["", nil]))

    missing =
      for target <- required_targets(regime), target not in targets do
        "Choose a column for #{label(target, definitions)}."
      end

    doubled =
      for {target, count} <- Enum.frequencies(targets), count > 1 do
        "#{label(target, definitions)} is chosen for #{count} columns. Pick one."
      end

    case missing ++ doubled do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  # ── Rows ───────────────────────────────────────────────────────────────────

  @doc """
  Builds and sorts every row. The first data row is spreadsheet row 2.

  Duplicates are found against the clients already kept (not in the Bin) and
  against earlier ready rows in the same file: by GSTIN or tax number, or by
  name and phone together.
  """
  @spec classify([[String.t()]], map, String.t(), list) :: [row]
  def classify(rows, mapping, regime, definitions) do
    existing = existing_keys()

    {classified, _seen} =
      rows
      |> Enum.with_index(2)
      |> Enum.map_reduce(MapSet.new(), fn {values, row_number}, seen ->
        attrs = build_attrs(values, mapping, regime, definitions)
        keys = duplicate_keys(attrs)

        base = %{
          row: row_number,
          name: Map.get(attrs, "name") || "",
          phone: phone_label(attrs),
          attrs: attrs,
          errors: []
        }

        cond do
          key = Enum.find(keys, &MapSet.member?(existing, &1)) ->
            {%{base | errors: [existing_message(key)]} |> Map.put(:status, :duplicate), seen}

          key = Enum.find(keys, &MapSet.member?(seen, &1)) ->
            {%{base | errors: [repeat_message(key)]} |> Map.put(:status, :duplicate), seen}

          true ->
            changeset = changeset(attrs, regime, definitions)

            if changeset.valid? do
              {Map.put(base, :status, :ready), Enum.into(keys, seen)}
            else
              {%{base | errors: error_messages(changeset, definitions)}
               |> Map.put(:status, :invalid), seen}
            end
        end
      end)

    classified
  end

  @doc """
  The insert changeset for one row's attrs. Same rules as the client form;
  the custom field definitions are passed in so each row costs no query.
  """
  def changeset(attrs, regime, definitions) do
    {custom, standard} = Map.pop(attrs, "custom_fields", %{})

    %Client{}
    |> Client.changeset(standard, regime)
    |> CustomFields.cast("client", %{"custom_fields" => custom}, definitions)
  end

  @doc "Client attrs (string keys) from one row's values."
  def build_attrs(values, mapping, regime, definitions) do
    raw =
      for {index, target} <- mapping,
          target not in ["", nil],
          value = values |> Enum.at(String.to_integer(index)) |> clean(),
          value != "",
          into: %{},
          do: {target, value}

    {custom_raw, standard_raw} =
      Map.split_with(raw, fn {target, _value} -> String.starts_with?(target, @custom_prefix) end)

    standard_raw
    |> Enum.reduce(%{}, fn {target, value}, attrs -> put_value(attrs, target, value, regime) end)
    |> put_country(regime)
    |> put_phone(standard_raw)
    |> put_client_type(regime)
    |> Map.put("shipping_same_as_billing", true)
    |> Map.put("custom_fields", custom_values(custom_raw, definitions))
  end

  defp clean(nil), do: ""
  defp clean(value), do: value |> to_string() |> String.trim()

  defp put_value(attrs, "billing_state", value, "gst"),
    do: Map.put(attrs, "billing_state", match_state(value))

  defp put_value(attrs, target, value, _regime) when target in ["gstin", "pan", "tax_number"],
    do: Map.put(attrs, target, value |> String.replace(~r/[\s\-.]/, "") |> String.upcase())

  defp put_value(attrs, "country", value, _regime),
    do: Map.put(attrs, "country", country_code(value))

  defp put_value(attrs, "business_type", value, _regime),
    do: Map.put(attrs, "business_type", pick(value, Client.business_types()))

  defp put_value(attrs, "category", value, _regime),
    do: Map.put(attrs, "category", pick(value, Client.categories()))

  defp put_value(attrs, "status", value, _regime),
    do: Map.put(attrs, "status", status(value))

  defp put_value(attrs, "client_type", value, _regime),
    do: Map.put(attrs, "client_type", client_type(value))

  defp put_value(attrs, target, value, _regime)
       when target in ["credit_limit", "opening_balance"],
       do: Map.put(attrs, target, amount(value))

  defp put_value(attrs, "payment_terms_days", value, _regime),
    do: Map.put(attrs, "payment_terms_days", terms(value))

  # Phone and its code are settled together in put_phone/2.
  defp put_value(attrs, target, _value, _regime) when target in ["phone", "phone_country_code"],
    do: attrs

  defp put_value(attrs, target, value, _regime), do: Map.put(attrs, target, value)

  # A GSTIN business's clients are in India unless the file says otherwise.
  defp put_country(attrs, "gst"), do: Map.put_new(attrs, "country", "IN")
  defp put_country(attrs, _vat), do: attrs

  # "+91 98765 43210", "0091-9876543210", "919876543210" and "09876543210" are
  # all +91 9876543210. A code in its own column wins; otherwise the number's
  # own prefix, then the country's.
  defp put_phone(attrs, raw) do
    given_code = raw |> Map.get("phone_country_code") |> dial_code()
    phone = Map.get(raw, "phone")

    {prefix_code, digits} = split_phone(phone)
    code = given_code || prefix_code || Map.get(@dial_codes, Map.get(attrs, "country")) || "+91"

    digits = trim_trunk(digits, code)

    attrs
    |> Map.put("phone_country_code", code)
    |> then(fn attrs -> if digits, do: Map.put(attrs, "phone", digits), else: attrs end)
  end

  defp split_phone(nil), do: {nil, nil}

  defp split_phone(phone) do
    compact = String.replace(phone, ~r/[\s\-().\/]/, "")

    international =
      cond do
        String.starts_with?(compact, "+") -> String.trim_leading(compact, "+")
        String.starts_with?(compact, "00") -> String.replace_prefix(compact, "00", "")
        true -> nil
      end

    case international && longest_code(international) do
      nil -> {nil, compact}
      code -> {code, String.replace_prefix(international, String.trim_leading(code, "+"), "")}
    end
  end

  defp longest_code(digits) do
    Client.country_codes()
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find(&String.starts_with?(digits, String.trim_leading(&1, "+")))
  end

  defp trim_trunk(nil, _code), do: nil

  defp trim_trunk(digits, "+91") do
    cond do
      String.length(digits) == 12 and String.starts_with?(digits, "91") ->
        binary_part(digits, 2, 10)

      String.length(digits) == 11 and String.starts_with?(digits, "0") ->
        binary_part(digits, 1, 10)

      true ->
        digits
    end
  end

  defp trim_trunk(digits, _code), do: digits

  defp dial_code(nil), do: nil

  defp dial_code(value) do
    code = "+" <> (value |> String.replace(~r/[^\d]/, ""))
    if code in Client.country_codes(), do: code, else: nil
  end

  defp country_code(value) do
    upper = value |> String.trim() |> String.upcase()
    Map.get(@country_names, upper, upper)
  end

  # Blank type: a GSTIN or tax number says the client is registered.
  defp put_client_type(%{"client_type" => _given} = attrs, _regime), do: attrs

  defp put_client_type(attrs, regime) do
    id = if regime == "vat", do: Map.get(attrs, "tax_number"), else: Map.get(attrs, "gstin")
    Map.put(attrs, "client_type", if(id, do: "Registered Business", else: "Unregistered"))
  end

  defp client_type(value) do
    key = normalize(value)

    Enum.find(Client.client_types(), &(normalize(&1) == key)) ||
      Map.get(@client_type_synonyms, key) ||
      value
  end

  defp status(value) do
    case normalize(value) do
      v when v in ["enabled", "yes", "true", "1"] -> "Active"
      v when v in ["disabled", "no", "false", "0"] -> "Inactive"
      _other -> pick(value, Client.statuses())
    end
  end

  # The allowed value matching case-insensitively, or the value as given
  # (which the changeset then reports).
  defp pick(value, allowed) do
    key = normalize(value)
    Enum.find(allowed, value, &(normalize(&1) == key))
  end

  @doc false
  # "Tamil Nadu", "tamil nadu (33)", "33", "TN"-less: names and GST codes only.
  def match_state(value) do
    states = EWayBillForm.states()
    key = value |> String.replace("&", " and ") |> normalize()

    Enum.find(states, fn state ->
      name = state |> String.replace(~r/\s*\(\d{2}\)$/, "")

      normalize(String.replace(state, "&", " and ")) == key or
        normalize(String.replace(name, "&", " and ")) == key or
        QuantumBilling.GST.state_code(state) == String.pad_leading(key, 2, "0")
    end) || value
  end

  defp amount(value) do
    value
    |> String.replace(~r/(?i)\b(rs|inr|aed|usd|gbp|eur|sar)\b\.?/u, "")
    |> String.replace(~r/[₹$€£,\s]/u, "")
  end

  # "Net 30", "30 days" => "30"; "Due on receipt" => "0".
  defp terms(value) do
    cond do
      match = Regex.run(~r/\d+/, value) -> hd(match)
      String.contains?(String.downcase(value), "receipt") -> "0"
      true -> value
    end
  end

  defp custom_values(custom_raw, definitions) do
    by_key = Map.new(definitions, &{&1.key, &1})

    for {@custom_prefix <> key, value} <- custom_raw,
        definition = Map.get(by_key, key),
        into: %{} do
      {key, custom_value(definition, value)}
    end
  end

  defp custom_value(%{type: "multi_select"}, value),
    do: value |> String.split([";", ",", "|"]) |> Enum.map(&String.trim/1)

  defp custom_value(%{type: "boolean"}, value) do
    case normalize(value) do
      v when v in ["yes", "y", "true", "1", "on"] -> "true"
      v when v in ["no", "n", "false", "0", "off"] -> "false"
      _other -> value
    end
  end

  defp custom_value(%{type: "money"}, value), do: amount(value)
  defp custom_value(_definition, value), do: value

  # ── Duplicates ─────────────────────────────────────────────────────────────

  defp existing_keys do
    from(c in Client.kept(), select: {c.gstin, c.tax_number, c.name, c.phone})
    |> Repo.all()
    |> Enum.flat_map(fn {gstin, tax_number, name, phone} ->
      keys(gstin, tax_number, name, phone)
    end)
    |> MapSet.new()
  end

  defp duplicate_keys(attrs) do
    keys(attrs["gstin"], attrs["tax_number"], attrs["name"], attrs["phone"])
  end

  defp keys(gstin, tax_number, name, phone) do
    [
      present(gstin) && {:gstin, String.upcase(gstin)},
      present(tax_number) && {:tax_number, String.upcase(tax_number)},
      present(name) && present(phone) &&
        {:name_phone, normalize(name), String.replace(phone, ~r/[^\d]/, "")}
    ]
    |> Enum.filter(& &1)
  end

  defp present(value), do: is_binary(value) and String.trim(value) != ""

  defp existing_message({:gstin, gstin}), do: "A client with GSTIN #{gstin} already exists."

  defp existing_message({:tax_number, number}),
    do: "A client with tax number #{number} already exists."

  defp existing_message({:name_phone, _, _}),
    do: "A client with this name and phone already exists."

  defp repeat_message({:gstin, _}), do: "Same GSTIN as an earlier row in this file."
  defp repeat_message({:tax_number, _}), do: "Same tax number as an earlier row in this file."

  defp repeat_message({:name_phone, _, _}),
    do: "Same name and phone as an earlier row in this file."

  defp phone_label(%{"phone" => phone, "phone_country_code" => code}), do: "#{code} #{phone}"
  defp phone_label(_attrs), do: nil

  # ── Errors ─────────────────────────────────────────────────────────────────

  @doc "A changeset's errors as sentences naming the field."
  def error_messages(changeset, definitions) do
    changeset.errors
    |> Enum.map(fn
      # Custom field messages already start with the field's label.
      {:custom_fields, {message, _opts}} ->
        interpolate(message, []) <> "."

      {field, {message, opts}} ->
        "#{label(to_string(field), definitions)} #{interpolate(message, opts)}."
    end)
    |> Enum.uniq()
  end

  defp interpolate(message, opts) do
    Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
