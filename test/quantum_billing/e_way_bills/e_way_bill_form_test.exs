defmodule QuantumBilling.EWayBills.EWayBillFormTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.EWayBills.EWayBillForm

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "supply_type" => "Outward Supply",
        "sub_type" => "Supply",
        "document_type" => "Tax Invoice",
        "document_no" => "INV-2024-0001",
        "document_date" => "2024-05-28",
        "transaction_type" => "Regular",
        "from_party" => "ABC Solutions Private Limited",
        "from_state" => "Maharashtra (27)",
        "to_party" => "V2V Technologies",
        "to_state" => "Maharashtra (27)",
        "total_goods_value" => "60000",
        "cgst_value" => "5400",
        "sgst_value" => "5400",
        "transport_mode" => "Road",
        "vehicle_no" => "MH01AB1234",
        "from_place" => "Mumbai",
        "to_place" => "Pune"
      },
      overrides
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  describe "changeset/2" do
    test "accepts a fully filled consignment" do
      changeset = EWayBillForm.changeset(%EWayBillForm{}, valid_attrs())

      assert changeset.valid?
    end

    test "requires every field the portal marks mandatory" do
      changeset = EWayBillForm.changeset(%EWayBillForm{}, %{})
      errors = errors_on(changeset)

      for field <- [
            :supply_type,
            :sub_type,
            :document_type,
            :document_no,
            :document_date,
            :transaction_type,
            :from_party,
            :from_state,
            :to_party,
            :to_state,
            :total_goods_value,
            :transport_mode,
            :vehicle_no,
            :from_place,
            :to_place
          ] do
        assert ["can't be blank"] = errors[field], "expected #{field} to be required"
      end
    end

    test "leaves the optional fields alone" do
      changeset = EWayBillForm.changeset(%EWayBillForm{}, valid_attrs())
      errors = errors_on(changeset)

      refute Map.has_key?(errors, :transporter_name)
      refute Map.has_key?(errors, :transporter_id)
      refute Map.has_key?(errors, :remarks)
      refute Map.has_key?(errors, :from_gstin)
    end

    test "rejects a malformed vehicle number" do
      changeset = EWayBillForm.changeset(%EWayBillForm{}, valid_attrs(%{"vehicle_no" => "AB-12"}))

      assert %{vehicle_no: ["must look like MH01AB1234"]} = errors_on(changeset)
    end

    test "normalizes the vehicle number to upper case without spaces" do
      changeset =
        EWayBillForm.changeset(%EWayBillForm{}, valid_attrs(%{"vehicle_no" => "mh 01 ab 1234"}))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :vehicle_no) == "MH01AB1234"
    end

    test "rejects a transporter id that is not a GSTIN" do
      changeset =
        EWayBillForm.changeset(%EWayBillForm{}, valid_attrs(%{"transporter_id" => "12345"}))

      assert %{transporter_id: ["must be a 15-character GSTIN"]} = errors_on(changeset)
    end

    test "accepts a valid GSTIN for either party" do
      changeset =
        EWayBillForm.changeset(
          %EWayBillForm{},
          valid_attrs(%{
            "from_gstin" => "27AABCA1234A1Z5",
            "to_gstin" => "27AAACPJ8542D1ZS"
          })
        )

      assert changeset.valid?
    end

    test "requires goods to have a value" do
      changeset =
        EWayBillForm.changeset(%EWayBillForm{}, valid_attrs(%{"total_goods_value" => "0"}))

      assert %{total_goods_value: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "rejects negative tax amounts" do
      changeset = EWayBillForm.changeset(%EWayBillForm{}, valid_attrs(%{"cgst_value" => "-1"}))

      assert %{cgst_value: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end

    test "caps remarks at 500 characters" do
      changeset =
        EWayBillForm.changeset(
          %EWayBillForm{},
          valid_attrs(%{"remarks" => String.duplicate("x", 501)})
        )

      assert %{remarks: ["should be at most 500 character(s)"]} = errors_on(changeset)
    end

    test "rejects values outside the published option lists" do
      changeset =
        EWayBillForm.changeset(%EWayBillForm{}, valid_attrs(%{"transport_mode" => "Teleport"}))

      assert %{transport_mode: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "validate/2" do
    test "flags the changeset so errors render while typing" do
      changeset = EWayBillForm.validate(%EWayBillForm{}, %{"document_no" => "INV-1"})

      assert changeset.action == :validate
    end
  end

  describe "total_invoice_value/1" do
    test "sums goods, taxes and other charges from a changeset" do
      changeset = EWayBillForm.changeset(%EWayBillForm{}, valid_attrs(%{"other_amount" => "500"}))

      assert EWayBillForm.total_invoice_value(changeset) == 71_300
    end

    test "treats missing amounts as zero" do
      changeset = EWayBillForm.changeset(%EWayBillForm{}, %{"total_goods_value" => "1000"})

      assert EWayBillForm.total_invoice_value(changeset) == 1000
    end

    test "works on an applied struct too" do
      form = %EWayBillForm{total_goods_value: 100, cgst_value: 9, sgst_value: 9}

      assert EWayBillForm.total_invoice_value(form) == 118
    end
  end

  describe "generate_number/0" do
    test "mints a 12-digit e-way bill number" do
      assert EWayBillForm.generate_number() =~ ~r/^\d{12}$/
    end
  end
end
