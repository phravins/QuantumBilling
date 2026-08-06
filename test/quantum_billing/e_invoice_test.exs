defmodule QuantumBilling.EInvoiceTest do
  @moduledoc """
  The GST e-invoice (INV-01) data export.

  Assertions are made against the re-parsed tree rather than the string. String
  matching on generated XML passes just as happily for malformed output, which is
  the one failure that matters here — a file an accountant cannot open.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.EInvoice
  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  setup do
    {:ok, organization} =
      Settings.update_section(
        Settings.ensure_organization(),
        %{
          "company_name" => "Acme Traders Private Limited",
          "address" => "221B Example Street\nAndheri East",
          "city" => "Mumbai",
          "pincode" => "400001",
          "gstin" => "27AABCA1234A1Z5",
          "state" => "Maharashtra (27)"
        },
        :general
      )

    %{organization: organization}
  end

  defp invoice(attrs \\ %{}, item_attrs \\ %{}) do
    item =
      Map.merge(
        %{
          "description" => "Design retainer",
          "hsn_sac" => "998311",
          "quantity" => "2",
          "unit" => "Hrs",
          "rate" => "500",
          "tax_rate" => "18"
        },
        item_attrs
      )

    {:ok, invoice} =
      Invoices.create_invoice(
        Map.merge(
          %{
            "invoice_date" => Date.to_iso8601(~D[2026-04-18]),
            "place_of_supply" => "Maharashtra (27)",
            "client_name" => "Northwind Traders",
            "client_gstin" => "27AAACN1234C1ZP",
            "client_state" => "Maharashtra (27)",
            "client_billing_address" => "14 Harbour Road\nColaba",
            "client_city" => "Mumbai",
            "client_pincode" => "400002",
            "items" => %{"0" => item}
          },
          attrs
        )
      )

    invoice
  end

  # The tree, so assertions are about structure rather than about a string that
  # happens to contain the right characters somewhere.
  defp tree(invoice) do
    {:ok, xml} = EInvoice.xml_for(invoice)
    {:ok, parsed} = Saxy.SimpleForm.parse_string(xml)
    parsed
  end

  defp text(tree, path), do: tree |> at(path) |> content()

  defp at({_name, _attrs, children}, [step | rest]) do
    children
    |> Enum.filter(&match?({n, _, _} when is_binary(n), &1))
    |> Enum.find(fn {name, _attrs, _kids} -> name == step end)
    |> case do
      nil -> nil
      found -> at(found, rest)
    end
  end

  defp at(node, []), do: node

  defp content(nil), do: nil
  defp content({_name, _attrs, children}), do: children |> Enum.filter(&is_binary/1) |> Enum.join()

  defp names({_name, _attrs, children}) do
    for {name, _attrs, _kids} <- children, is_binary(name), do: name
  end

  defp all_names(node), do: node |> flatten() |> Enum.uniq()

  defp flatten({name, _attrs, children}) when is_binary(name) do
    [name | Enum.flat_map(children, &flatten/1)]
  end

  defp flatten(_other), do: []

  describe "the document" do
    test "carries the schema's own shape" do
      tree = tree(invoice())

      assert {"Invoice", _attrs, _children} = tree

      assert names(tree) == [
               "Version",
               "TranDtls",
               "DocDtls",
               "SellerDtls",
               "BuyerDtls",
               "ItemList",
               "ValDtls"
             ]

      assert text(tree, ["Version"]) == "1.1"
    end

    # The whole point of being honest about what this is. If somebody later adds
    # a fabricated IRN or an unsigned QR, this is what should stop them.
    test "carries no IRN, acknowledgement or QR code" do
      names = all_names(tree(invoice()))

      for forged <- ~w(Irn AckNo AckDt SignedInvoice SignedQRCode QRCodeUrl) do
        refute forged in names, "the export emitted #{forged}, which only the IRP can issue"
      end
    end

    test "says in the file that it is not a registered e-invoice" do
      {:ok, xml} = EInvoice.xml_for(invoice())

      assert xml =~ "NOT a registered e-invoice"
      assert xml =~ "no IRN"
    end
  end

  describe "the parties" do
    test "a buyer with a GSTIN is B2B and carries it" do
      tree = tree(invoice())

      assert text(tree, ["TranDtls", "SupTyp"]) == "B2B"
      assert text(tree, ["BuyerDtls", "Gstin"]) == "27AAACN1234C1ZP"
    end

    # An unregistered buyer is a legitimate supply, not an error — but the
    # element must be absent rather than empty.
    test "a buyer without a GSTIN is B2C and the element is omitted" do
      tree = tree(invoice(%{"client_gstin" => nil}))

      assert text(tree, ["TranDtls", "SupTyp"]) == "B2C"
      refute "Gstin" in names(at(tree, ["BuyerDtls"]))
    end

    test "the seller comes from the organisation, split into its parts" do
      tree = tree(invoice())

      assert text(tree, ["SellerDtls", "Gstin"]) == "27AABCA1234A1Z5"
      assert text(tree, ["SellerDtls", "LglNm"]) == "Acme Traders Private Limited"
      assert text(tree, ["SellerDtls", "Addr1"]) == "221B Example Street"
      assert text(tree, ["SellerDtls", "Addr2"]) == "Andheri East"
      assert text(tree, ["SellerDtls", "Loc"]) == "Mumbai"
      assert text(tree, ["SellerDtls", "Pin"]) == "400001"
      assert text(tree, ["SellerDtls", "Stcd"]) == "27"
    end

    test "state codes are the two digits out of the state label" do
      tree = tree(invoice())

      assert text(tree, ["BuyerDtls", "Pos"]) == "27"
      assert text(tree, ["BuyerDtls", "Stcd"]) == "27"
    end
  end

  describe "the figures" do
    test "an intra-state supply splits into CGST and SGST" do
      tree = tree(invoice())

      assert text(tree, ["ValDtls", "CgstVal"]) == "90.00"
      assert text(tree, ["ValDtls", "SgstVal"]) == "90.00"
      assert text(tree, ["ValDtls", "IgstVal"]) == "0.00"

      item = at(tree, ["ItemList", "Item"])
      assert content(at(item, ["CgstAmt"])) == "90.00"
      assert content(at(item, ["IgstAmt"])) == "0.00"
    end

    test "an inter-state supply is all IGST" do
      tree = tree(invoice(%{"place_of_supply" => "Karnataka (29)", "client_state" => "Karnataka (29)"}))

      assert text(tree, ["ValDtls", "IgstVal"]) == "180.00"
      assert text(tree, ["ValDtls", "CgstVal"]) == "0.00"
      assert text(tree, ["ValDtls", "SgstVal"]) == "0.00"

      item = at(tree, ["ItemList", "Item"])
      assert content(at(item, ["IgstAmt"])) == "180.00"
      assert content(at(item, ["CgstAmt"])) == "0.00"
    end

    test "the parts add up to the total" do
      tree = tree(invoice())
      number = fn field -> tree |> text(["ValDtls", field]) |> String.to_float() end

      sum =
        ~w(AssVal CgstVal SgstVal IgstVal CesVal RndOffAmt)
        |> Enum.map(number)
        |> Enum.sum()

      assert Float.round(sum, 2) == number.("TotInvVal")
    end

    test "amounts carry two decimals" do
      tree = tree(invoice())

      for field <- ~w(AssVal CgstVal TotInvVal) do
        assert tree |> text(["ValDtls", field]) |> String.contains?("."),
               "#{field} was not written as a decimal"
      end
    end

    test "a SAC marks the line as a service, an HSN as goods" do
      service = tree(invoice()) |> at(["ItemList", "Item", "IsServc"]) |> content()
      goods = invoice(%{}, %{"hsn_sac" => "847130"}) |> tree() |> at(["ItemList", "Item", "IsServc"]) |> content()

      assert service == "Y"
      assert goods == "N"
    end

    test "the unit is the schema's code, not the form's label" do
      assert tree(invoice()) |> at(["ItemList", "Item", "Unit"]) |> content() == "HRS"
    end

    test "the date is written the way the schema asks" do
      assert text(tree(invoice()), ["DocDtls", "Dt"]) == "18/04/2026"
    end
  end

  describe "escaping" do
    # `Saxy.encode!/2` emits a bare binary child unescaped, so this is what
    # catches a value being passed as a string rather than a character node.
    test "markup characters in a name survive the round trip" do
      name = ~s(Smith & Sons <"Exports"> Ltd)

      assert text(tree(invoice(%{"client_name" => name})), ["BuyerDtls", "LglNm"]) == name
    end
  end

  describe "refusing to export" do
    test "a document type the schema cannot describe" do
      assert {:error, problems} = EInvoice.xml_for(invoice(%{"invoice_type" => "Bill of Supply"}))
      assert Enum.any?(problems, &(&1 =~ "Bill of Supply"))
    end

    test "a cancelled invoice" do
      assert {:error, problems} = EInvoice.xml_for(invoice(%{"status" => "Cancelled"}))
      assert Enum.any?(problems, &(&1 =~ "cancelled"))
    end

    test "an invalid buyer GSTIN" do
      assert {:error, problems} = EInvoice.xml_for(invoice(%{"client_gstin" => "NOTAGSTIN"}))
      assert Enum.any?(problems, &(&1 =~ "client's GSTIN"))
    end

    # The likeliest real failure: HSN is optional on a line item here and
    # mandatory in the schema.
    test "a line with no HSN, naming the line and where to find one" do
      assert {:error, problems} = EInvoice.xml_for(invoice(%{}, %{"hsn_sac" => nil}))

      message = Enum.find(problems, &(&1 =~ "HSN"))
      assert message =~ "line 1"
      assert message =~ "HSN Finder"
    end

    test "a missing seller PIN, pointing at where to set it" do
      {:ok, _organization} =
        Settings.get_organization()
        |> Ecto.Changeset.change(%{pincode: nil})
        |> Repo.update()

      assert {:error, problems} = EInvoice.xml_for(invoice())
      assert Enum.any?(problems, &(&1 =~ "PIN code" and &1 =~ "Settings"))
    end

    test "a missing client city" do
      assert {:error, problems} = EInvoice.xml_for(invoice(%{"client_city" => nil}))
      assert Enum.any?(problems, &(&1 =~ "client's city"))
    end

    # Every problem at once, so a user fixes them in one pass rather than
    # discovering them one download at a time.
    test "reports every problem together" do
      {:ok, _organization} =
        Settings.get_organization()
        |> Ecto.Changeset.change(%{pincode: nil, city: nil})
        |> Repo.update()

      assert {:error, problems} = EInvoice.xml_for(invoice(%{}, %{"hsn_sac" => nil}))
      assert length(problems) >= 3
    end
  end
end
