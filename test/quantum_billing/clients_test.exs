defmodule QuantumBilling.ClientsTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Clients

  # A minimally valid client. Individual tests override just the field under
  # test, so a failure points at one rule rather than a wall of attributes.
  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "client_type" => "Unregistered",
        "name" => "Acme Traders",
        "phone" => "9876543210",
        "billing_line1" => "123 Business Park",
        "billing_city" => "Mumbai",
        "billing_state" => "Maharashtra (27)",
        "billing_pin" => "400093"
      },
      overrides
    )
  end

  defp registered(overrides \\ %{}) do
    attrs(
      Map.merge(
        %{"client_type" => "Registered Business", "gstin" => "27AABCA1234A1Z5"},
        overrides
      )
    )
  end

  describe "GSTIN requirement follows the client type" do
    test "a registered business must supply one" do
      assert {:error, changeset} =
               Clients.create_client(attrs(%{"client_type" => "Registered Business"}))

      assert %{gstin: ["is required for a Registered Business"]} = errors_on(changeset)
    end

    test "composition and SEZ must supply one" do
      for type <- ["Composition Scheme", "SEZ Unit"] do
        assert {:error, changeset} = Clients.create_client(attrs(%{"client_type" => type}))
        assert %{gstin: [_]} = errors_on(changeset)
      end
    end

    test "an unregistered client or a consumer does not" do
      # B2C invoicing needs these.
      for type <- ["Unregistered", "Consumer", "Overseas"] do
        assert {:ok, client} =
                 Clients.create_client(attrs(%{"client_type" => type, "name" => "Buyer #{type}"}))

        assert client.gstin == nil
      end
    end

    test "gstin_required?/1 is the single source of the rule" do
      assert Clients.gstin_required?("Registered Business")
      assert Clients.gstin_required?("Composition Scheme")
      refute Clients.gstin_required?("Unregistered")
      refute Clients.gstin_required?("Consumer")
    end
  end

  describe "GSTIN validation" do
    test "accepts a valid one and upcases it" do
      assert {:ok, client} = Clients.create_client(registered(%{"gstin" => "27aabca1234a1z5"}))
      assert client.gstin == "27AABCA1234A1Z5"
    end

    test "rejects a malformed one" do
      assert {:error, changeset} = Clients.create_client(registered(%{"gstin" => "NOPE"}))
      assert %{gstin: ["is not a valid GSTIN"]} = errors_on(changeset)
    end

    test "rejects a PAN that contradicts the embedded one" do
      assert {:error, changeset} = Clients.create_client(registered(%{"pan" => "ZZZZZ9999Z"}))
      assert %{pan: ["does not match the PAN in the GSTIN (AABCA1234A)"]} = errors_on(changeset)
    end

    test "accepts the PAN embedded in the GSTIN" do
      assert {:ok, _} = Clients.create_client(registered(%{"pan" => "AABCA1234A"}))
    end

    test "rejects a state that contradicts the GSTIN's state code" do
      # 29 is Karnataka; the address says Maharashtra (27).
      assert {:error, changeset} =
               Clients.create_client(registered(%{"gstin" => "29AABCU9603R1ZM"}))

      assert %{billing_state: ["does not match the GSTIN's state code (29)"]} =
               errors_on(changeset)
    end

    test "accepts a state that agrees with the GSTIN" do
      assert {:ok, _} =
               Clients.create_client(
                 registered(%{"gstin" => "29AABCU9603R1ZM", "billing_state" => "Karnataka (29)"})
               )
    end
  end

  describe "GSTIN uniqueness" do
    test "the same GSTIN cannot belong to two clients" do
      assert {:ok, _} = Clients.create_client(registered())

      assert {:error, changeset} = Clients.create_client(registered(%{"name" => "Copycat"}))
      assert %{gstin: ["is already registered to another client"]} = errors_on(changeset)
    end

    test "many clients may have no GSTIN at all" do
      # The index is partial; a plain unique index would treat every missing
      # GSTIN as a collision.
      assert {:ok, _} = Clients.create_client(attrs(%{"name" => "Walk-in One"}))
      assert {:ok, _} = Clients.create_client(attrs(%{"name" => "Walk-in Two"}))
      assert {:ok, _} = Clients.create_client(attrs(%{"name" => "Walk-in Three"}))

      assert length(Clients.list_clients()) == 3
    end
  end

  describe "required fields" do
    test "name and phone are required" do
      assert {:error, changeset} =
               Clients.create_client(attrs(%{"name" => "", "phone" => ""}))

      errors = errors_on(changeset)
      assert errors.name == ["can't be blank"]
      assert errors.phone == ["can't be blank"]
    end

    test "the billing address is required" do
      assert {:error, changeset} =
               Clients.create_client(
                 attrs(%{
                   "billing_line1" => "",
                   "billing_city" => "",
                   "billing_state" => "",
                   "billing_pin" => ""
                 })
               )

      errors = errors_on(changeset)
      assert errors.billing_line1 == ["can't be blank"]
      assert errors.billing_city == ["can't be blank"]
      assert errors.billing_state == ["can't be blank"]
      assert errors.billing_pin == ["can't be blank"]
    end
  end

  describe "shape validation" do
    test "an Indian phone number is ten digits" do
      assert {:error, changeset} = Clients.create_client(attrs(%{"phone" => "12345"}))
      assert %{phone: ["must be 10 digits"]} = errors_on(changeset)
    end

    test "spaces and dashes in a phone number are stripped, not rejected" do
      assert {:ok, client} = Clients.create_client(attrs(%{"phone" => "98765 43210"}))
      assert client.phone == "9876543210"
    end

    test "other country codes allow other lengths" do
      assert {:ok, _} =
               Clients.create_client(
                 attrs(%{"phone_country_code" => "+1", "phone" => "4155551234"})
               )
    end

    test "a PIN code is six digits" do
      assert {:error, changeset} = Clients.create_client(attrs(%{"billing_pin" => "40009"}))
      assert %{billing_pin: ["must be 6 digits"]} = errors_on(changeset)
    end

    test "an email must look like one when given, and is optional" do
      assert {:error, changeset} = Clients.create_client(attrs(%{"email" => "not an email"}))
      assert %{email: [_]} = errors_on(changeset)

      assert {:ok, client} = Clients.create_client(attrs(%{"email" => ""}))
      assert client.email == nil
    end

    test "an unknown state is rejected" do
      assert {:error, changeset} = Clients.create_client(attrs(%{"billing_state" => "Atlantis"}))
      assert %{billing_state: ["is invalid"]} = errors_on(changeset)
    end

    test "optional dropdowns may be left unset" do
      assert {:ok, client} =
               Clients.create_client(attrs(%{"business_type" => "", "category" => ""}))

      assert client.business_type == nil
      assert client.category == nil
    end

    test "trade terms cannot be negative" do
      assert {:error, changeset} = Clients.create_client(attrs(%{"credit_limit" => -1}))
      assert %{credit_limit: [_]} = errors_on(changeset)
    end
  end

  describe "shipping address" do
    test "is copied from billing when 'same as billing' is set" do
      assert {:ok, client} = Clients.create_client(attrs())

      assert client.shipping_line1 == client.billing_line1
      assert client.shipping_city == "Mumbai"
      assert client.shipping_state == "Maharashtra (27)"
      assert client.shipping_pin == "400093"
    end

    test "is kept separate when it is its own address" do
      assert {:ok, client} =
               Clients.create_client(
                 attrs(%{
                   "shipping_same_as_billing" => "false",
                   "shipping_line1" => "Warehouse 4",
                   "shipping_city" => "Pune",
                   "shipping_state" => "Maharashtra (27)",
                   "shipping_pin" => "411001"
                 })
               )

      assert client.shipping_city == "Pune"
      assert client.billing_city == "Mumbai"
    end

    test "a bad billing PIN does not also report an invisible shipping error" do
      # While "same as billing" is on the shipping fields are not on screen, so
      # duplicating the error there would block the save with nothing to fix.
      assert {:error, changeset} = Clients.create_client(attrs(%{"billing_pin" => "40009"}))

      errors = errors_on(changeset)
      assert errors.billing_pin == ["must be 6 digits"]
      refute Map.has_key?(errors, :shipping_pin)
    end

    test "its own PIN is validated when it is separate" do
      assert {:error, changeset} =
               Clients.create_client(
                 attrs(%{"shipping_same_as_billing" => "false", "shipping_pin" => "123"})
               )

      assert %{shipping_pin: ["must be 6 digits"]} = errors_on(changeset)
    end
  end

  describe "defaults the list page depends on" do
    test "a new client is Active with nothing outstanding" do
      assert {:ok, client} = Clients.create_client(attrs())

      assert client.status == "Active"
      assert client.outstanding == 0
    end
  end

  describe "list_clients/0" do
    test "is empty to begin with" do
      assert Clients.list_clients() == []
    end

    test "returns clients alphabetically" do
      for name <- ["Zenith Co", "Acme Traders", "Marigold Ltd"] do
        {:ok, _} = Clients.create_client(attrs(%{"name" => name}))
      end

      assert Enum.map(Clients.list_clients(), & &1.name) == [
               "Acme Traders",
               "Marigold Ltd",
               "Zenith Co"
             ]
    end
  end

  describe "picker_options/2" do
    test "offers at most a screenful, whatever the directory holds" do
      for index <- 1..(Clients.picker_limit() + 20) do
        {:ok, _} =
          Clients.create_client(
            attrs(%{"name" => "Client #{String.pad_leading(to_string(index), 3, "0")}"})
          )
      end

      options = Clients.picker_options()

      assert length(options) == Clients.picker_limit()
      assert %{id: _, name: "Client 001"} = hd(options)
    end

    test "narrows to the search, across name, GSTIN and email" do
      {:ok, _} = Clients.create_client(attrs(%{"name" => "Northwind Traders"}))

      {:ok, _} =
        Clients.create_client(
          attrs(%{"name" => "Contoso Ltd", "email" => "accounts@contoso.test"})
        )

      assert [%{name: "Northwind Traders"}] = Clients.picker_options("northwind")
      assert [%{name: "Contoso Ltd"}] = Clients.picker_options("accounts@contoso")
      assert Clients.picker_options("nobody at all") == []
    end

    test "keeps the selected client even when the search excludes it" do
      {:ok, chosen} = Clients.create_client(attrs(%{"name" => "Northwind Traders"}))
      {:ok, _} = Clients.create_client(attrs(%{"name" => "Contoso Ltd"}))

      options = Clients.picker_options("contoso", chosen.id)

      # An invoice must keep showing its own client, or saving the form would
      # silently clear it.
      assert [%{name: "Northwind Traders"}, %{name: "Contoso Ltd"}] = options
    end

    test "lists the selected client once, not twice" do
      {:ok, chosen} = Clients.create_client(attrs(%{"name" => "Northwind Traders"}))

      assert [%{name: "Northwind Traders"}] = Clients.picker_options("northwind", chosen.id)
    end

    test "tolerates an id that is not one" do
      {:ok, _} = Clients.create_client(attrs(%{"name" => "Northwind Traders"}))

      assert [%{name: "Northwind Traders"}] = Clients.picker_options(nil, "not-an-id")
      assert [%{name: "Northwind Traders"}] = Clients.picker_options(nil, 999_999)
    end
  end

  describe "get_client/1" do
    test "answers nil rather than raising for anything that is not a client" do
      {:ok, client} = Clients.create_client(attrs())

      assert %{id: id} = Clients.get_client(to_string(client.id))
      assert id == client.id
      assert Clients.get_client(999_999) == nil
      assert Clients.get_client("12-not-an-id") == nil
      assert Clients.get_client("") == nil
      assert Clients.get_client(nil) == nil
    end
  end

  describe "get_client_by_name/1" do
    test "matches the whole name, ignoring case and surrounding spaces" do
      {:ok, client} = Clients.create_client(attrs(%{"name" => "Acme Traders"}))

      assert Clients.get_client_by_name("Acme Traders").id == client.id
      assert Clients.get_client_by_name("  acme TRADERS ").id == client.id
    end

    test "never matches part of a name" do
      {:ok, _client} = Clients.create_client(attrs(%{"name" => "Acme Traders"}))

      assert Clients.get_client_by_name("Acme") == nil
      assert Clients.get_client_by_name("Acme Traders Ltd") == nil
      assert Clients.get_client_by_name("Acme%") == nil
    end

    test "answers nil for nothing at all" do
      assert Clients.get_client_by_name("") == nil
      assert Clients.get_client_by_name("   ") == nil
      assert Clients.get_client_by_name(nil) == nil
    end

    test "the oldest client wins when a name is shared" do
      {:ok, first} = Clients.create_client(attrs(%{"name" => "Acme Traders"}))
      {:ok, _second} = Clients.create_client(attrs(%{"name" => "Acme Traders"}))

      assert Clients.get_client_by_name("Acme Traders").id == first.id
    end
  end
end
