defmodule QuantumBilling.InvoicesTest do
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Clients
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  # Maharashtra is the company's own state throughout, so "Maharashtra (27)"
  # means intra-state and anything else means inter-state.
  defp setup_company(_context) do
    {:ok, organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "ABC Solutions Private Limited",
          "gstin" => "27AABCA1234A1Z5",
          "state" => "Maharashtra (27)",
          "address" => "123 Business Park, Mumbai"
        },
        :general
      )

    %{organization: organization}
  end

  defp item(over \\ %{}) do
    Map.merge(
      %{
        "description" => "Web Development Services",
        "hsn_sac" => "998313",
        "quantity" => "1",
        "unit" => "Nos",
        "rate" => "50000",
        "tax_rate" => "18",
        "position" => "0"
      },
      over
    )
  end

  defp attrs(over \\ %{}) do
    Map.merge(
      %{
        "invoice_date" => "2024-05-28",
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "V2V Technologies",
        "items" => %{"0" => item()}
      },
      over
    )
  end

  describe "create_invoice/1" do
    setup :setup_company

    test "computes the totals from the screenshot" do
      # Two lines at 18%: 50,000 + 10,000 taxable, 10,800 tax split evenly.
      attrs =
        attrs(%{
          "items" => %{
            "0" => item(),
            "1" =>
              item(%{
                "description" => "Hosting Services",
                "hsn_sac" => "998422",
                "rate" => "10000",
                "position" => "1"
              })
          }
        })

      assert {:ok, invoice} = Invoices.create_invoice(attrs)

      assert invoice.total_items == 2
      assert invoice.total_quantity == 2
      assert invoice.taxable_value == 60_000
      assert invoice.cgst_amount == 5_400
      assert invoice.sgst_amount == 5_400
      assert invoice.igst_amount == 0
      assert invoice.grand_total == 70_800
    end

    test "a mixed-rate invoice taxes each line at its own rate" do
      attrs =
        attrs(%{
          "items" => %{
            # 18% of 50,000 = 9,000
            "0" => item(),
            # 5% of 10,000 = 500
            "1" => item(%{"rate" => "10000", "tax_rate" => "5", "position" => "1"})
          }
        })

      assert {:ok, invoice} = Invoices.create_invoice(attrs)

      assert invoice.taxable_value == 60_000
      assert invoice.cgst_amount + invoice.sgst_amount == 9_500
    end

    test "splits an odd tax without losing a rupee" do
      # 5% of 999 is 49 — halving twice would give 24 + 24 and quietly drop one.
      attrs = attrs(%{"items" => %{"0" => item(%{"rate" => "999", "tax_rate" => "5"})}})

      assert {:ok, invoice} = Invoices.create_invoice(attrs)

      assert invoice.cgst_amount + invoice.sgst_amount == 49
      assert invoice.grand_total == invoice.taxable_value + 49
    end

    test "the grand total always equals its parts" do
      attrs =
        attrs(%{
          "items" => %{
            "0" => item(%{"rate" => "333", "tax_rate" => "18"}),
            "1" => item(%{"rate" => "777", "tax_rate" => "12", "position" => "1"}),
            "2" => item(%{"rate" => "1111", "tax_rate" => "28", "position" => "2"})
          }
        })

      assert {:ok, invoice} = Invoices.create_invoice(attrs)

      assert invoice.grand_total ==
               invoice.taxable_value + invoice.cgst_amount + invoice.sgst_amount +
                 invoice.igst_amount + invoice.cess_amount + invoice.round_off
    end

    test "quantity multiplies the rate" do
      attrs = attrs(%{"items" => %{"0" => item(%{"quantity" => "3", "rate" => "1000"})}})

      assert {:ok, invoice} = Invoices.create_invoice(attrs)

      assert invoice.taxable_value == 3_000
      assert invoice.total_quantity == 3
    end
  end

  describe "intra-state versus inter-state" do
    setup :setup_company

    test "the company's own state splits into CGST and SGST" do
      assert {:ok, invoice} = Invoices.create_invoice(attrs())

      assert invoice.cgst_amount == 4_500
      assert invoice.sgst_amount == 4_500
      assert invoice.igst_amount == 0
    end

    test "a different state charges IGST at the full rate" do
      assert {:ok, invoice} =
               Invoices.create_invoice(attrs(%{"place_of_supply" => "Karnataka (29)"}))

      assert invoice.cgst_amount == 0
      assert invoice.sgst_amount == 0
      assert invoice.igst_amount == 9_000
    end

    test "either way the grand total is the same" do
      {:ok, intra} = Invoices.create_invoice(attrs())
      {:ok, inter} = Invoices.create_invoice(attrs(%{"place_of_supply" => "Karnataka (29)"}))

      assert intra.grand_total == inter.grand_total
    end
  end

  describe "invoice numbering" do
    setup :setup_company

    test "uses the organisation's series and advances it" do
      assert {:ok, first} = Invoices.create_invoice(attrs())
      assert first.invoice_number == "INV-0001"
      assert Settings.get_organization().invoice_next_number == 2

      assert {:ok, second} = Invoices.create_invoice(attrs())
      assert second.invoice_number == "INV-0002"
      assert Settings.get_organization().invoice_next_number == 3
    end

    test "respects a configured prefix and padding" do
      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{
            "invoice_prefix" => "GST",
            "invoice_next_number" => 42,
            "invoice_number_padding" => 5
          },
          :invoice
        )

      assert {:ok, invoice} = Invoices.create_invoice(attrs())
      assert invoice.invoice_number == "GST-00042"
    end

    test "numbers are unique" do
      # The transaction is what prevents a collision; the unique index is the
      # backstop that would make one loud rather than silent.
      {:ok, a} = Invoices.create_invoice(attrs())
      {:ok, b} = Invoices.create_invoice(attrs())
      {:ok, c} = Invoices.create_invoice(attrs())

      numbers = Enum.map([a, b, c], & &1.invoice_number)
      assert length(Enum.uniq(numbers)) == 3
    end

    test "a rejected invoice does not consume a number" do
      # No items, so the insert fails and the whole transaction rolls back.
      assert {:error, _changeset} = Invoices.create_invoice(attrs(%{"items" => %{}}))

      assert Settings.get_organization().invoice_next_number == 1
    end
  end

  describe "snapshots" do
    setup :setup_company

    test "the company details are copied onto the invoice" do
      assert {:ok, invoice} = Invoices.create_invoice(attrs())

      assert invoice.company_name == "ABC Solutions Private Limited"
      assert invoice.company_gstin == "27AABCA1234A1Z5"
      assert invoice.company_state == "Maharashtra (27)"
    end

    test "editing the company afterwards does not rewrite issued invoices" do
      {:ok, invoice} = Invoices.create_invoice(attrs())

      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name" => "Renamed Solutions Ltd"},
          :general
        )

      # An invoice is a legal document: it has to keep showing what was true
      # when it was issued.
      assert Invoices.get_invoice!(invoice.id).company_name == "ABC Solutions Private Limited"
    end

    test "editing the client afterwards does not rewrite issued invoices" do
      {:ok, client} =
        Clients.create_client(%{
          "client_type" => "Unregistered",
          "name" => "V2V Technologies",
          "phone" => "9876543210",
          "billing_line1" => "123 Business Park",
          "billing_city" => "Mumbai",
          "billing_state" => "Maharashtra (27)",
          "billing_pin" => "400093"
        })

      {:ok, invoice} =
        Invoices.create_invoice(
          attrs(%{"client_id" => client.id, "client_name" => "V2V Technologies"})
        )

      {:ok, _} = Clients.update_client(client, %{"name" => "V2V Technologies Renamed"})

      reloaded = Invoices.get_invoice!(invoice.id)
      assert reloaded.client_name == "V2V Technologies"
      # The link is kept for traceability even though the text is frozen.
      assert reloaded.client_id == client.id
    end
  end

  describe "validation" do
    setup :setup_company

    test "an invoice needs at least one item" do
      assert {:error, changeset} = Invoices.create_invoice(attrs(%{"items" => %{}}))
      assert %{items: ["add at least one item"]} = errors_on(changeset)
    end

    test "an item needs a description" do
      assert {:error, changeset} =
               Invoices.create_invoice(
                 attrs(%{"items" => %{"0" => item(%{"description" => ""})}})
               )

      assert %{items: [%{description: ["can't be blank"]}]} = errors_on(changeset)
    end

    test "quantity must be positive" do
      assert {:error, changeset} =
               Invoices.create_invoice(attrs(%{"items" => %{"0" => item(%{"quantity" => "0"})}}))

      assert %{items: [%{quantity: [_]}]} = errors_on(changeset)
    end

    test "a tax rate must be a statutory slab" do
      assert {:error, changeset} =
               Invoices.create_invoice(attrs(%{"items" => %{"0" => item(%{"tax_rate" => "7"})}}))

      assert %{items: [%{tax_rate: [message]}]} = errors_on(changeset)
      assert message =~ "GST slabs"
    end

    test "the invoice date and place of supply are required" do
      assert {:error, changeset} =
               Invoices.create_invoice(attrs(%{"invoice_date" => "", "place_of_supply" => ""}))

      errors = errors_on(changeset)
      assert errors.invoice_date == ["can't be blank"]
      assert errors.place_of_supply == ["can't be blank"]
    end

    test "the due date cannot precede the invoice date" do
      assert {:error, changeset} =
               Invoices.create_invoice(
                 attrs(%{"invoice_date" => "2024-05-28", "due_date" => "2024-05-01"})
               )

      assert %{due_date: ["cannot be before the invoice date"]} = errors_on(changeset)
    end

    test "an unknown place of supply is rejected" do
      assert {:error, changeset} =
               Invoices.create_invoice(attrs(%{"place_of_supply" => "Atlantis"}))

      assert %{place_of_supply: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "list_invoices/0" do
    setup :setup_company

    test "is empty to begin with" do
      assert Invoices.list_invoices() == []
    end

    test "returns the shape the list page renders" do
      {:ok, invoice} = Invoices.create_invoice(attrs())

      assert [row] = Invoices.list_invoices()
      assert row.id == invoice.id
      assert row.number == invoice.invoice_number
      assert row.client == "V2V Technologies"
      assert row.amount == invoice.grand_total
      assert row.status == "Draft"
      assert row.invoice_date
      assert row.due_date
    end

    test "a new invoice is a draft" do
      {:ok, invoice} = Invoices.create_invoice(attrs())
      assert invoice.status == "Draft"
    end
  end

  describe "get_invoice/1" do
    setup :setup_company

    test "loads the items in position order" do
      attrs =
        attrs(%{
          "items" => %{
            "0" => item(%{"description" => "First", "position" => "0"}),
            "1" => item(%{"description" => "Second", "position" => "1"}),
            "2" => item(%{"description" => "Third", "position" => "2"})
          }
        })

      {:ok, invoice} = Invoices.create_invoice(attrs)

      assert ["First", "Second", "Third"] =
               Invoices.get_invoice(invoice.id).items |> Enum.map(& &1.description)
    end

    test "is nil for an id that does not exist" do
      assert Invoices.get_invoice(999_999) == nil
    end

    test "is nil rather than raising for something that is not an id" do
      assert Invoices.get_invoice("not-an-id") == nil
    end
  end

  describe "without an organisation configured" do
    test "an invoice can still be created" do
      # A fresh installation has no settings row. Defaulting to intra-state and
      # numbering from 1 is better than refusing to invoice at all.
      assert {:ok, invoice} = Invoices.create_invoice(attrs())

      assert invoice.invoice_number == "INV-0001"
      assert invoice.cgst_amount == 4_500
      assert invoice.sgst_amount == 4_500
    end
  end
end
