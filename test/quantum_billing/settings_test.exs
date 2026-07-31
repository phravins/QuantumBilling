defmodule QuantumBilling.SettingsTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  defp save(attrs, section) do
    Settings.update_section(Settings.get_organization(), attrs, section)
  end

  describe "get_organization/0" do
    test "returns usable defaults on an empty database" do
      organization = Settings.get_organization()

      assert organization.id == nil
      assert organization.currency == "INR (₹) - Indian Rupee"
      assert organization.default_gst_rate == 18
      assert organization.invoice_prefix == "INV"
      assert organization.rows_per_page == 10
    end

    test "does not write a row just for being read" do
      Settings.get_organization()

      assert Repo.aggregate(Organization, :count) == 0
    end
  end

  describe "update_section/3" do
    test "inserts the first time and updates after, never creating a second row" do
      assert {:ok, first} = save(%{"company_name" => "Acme Traders"}, :general)
      assert first.id

      assert {:ok, second} = save(%{"company_name" => "Acme Traders Ltd"}, :general)

      assert second.id == first.id
      assert second.company_name == "Acme Traders Ltd"
      assert Repo.aggregate(Organization, :count) == 1
    end

    test "persists across a fresh read" do
      {:ok, _} = save(%{"company_name" => "Acme Traders", "phone" => "+91 98765 43210"}, :general)

      reloaded = Settings.get_organization()

      assert reloaded.company_name == "Acme Traders"
      assert reloaded.phone == "+91 98765 43210"
    end

    test "saving one section leaves the others alone" do
      {:ok, _} = save(%{"company_name" => "Acme Traders"}, :general)
      {:ok, _} = save(%{"default_gst_rate" => 12}, :tax)

      organization = Settings.get_organization()

      assert organization.company_name == "Acme Traders"
      assert organization.default_gst_rate == 12
    end
  end

  describe "general section" do
    test "requires a company name" do
      assert {:error, changeset} = save(%{"company_name" => ""}, :general)
      assert %{company_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts and upcases a valid GSTIN and PAN" do
      assert {:ok, organization} =
               save(
                 %{
                   "company_name" => "Acme",
                   "gstin" => "27aabca1234a1z5",
                   "pan" => "aabca1234a"
                 },
                 :general
               )

      assert organization.gstin == "27AABCA1234A1Z5"
      assert organization.pan == "AABCA1234A"
    end

    test "rejects a malformed GSTIN" do
      assert {:error, changeset} = save(%{"company_name" => "Acme", "gstin" => "NOPE"}, :general)
      assert %{gstin: ["is not a valid GSTIN"]} = errors_on(changeset)
    end

    test "rejects a PAN that contradicts the GSTIN" do
      assert {:error, changeset} =
               save(
                 %{"company_name" => "Acme", "gstin" => "27AABCA1234A1Z5", "pan" => "ZZZZZ9999Z"},
                 :general
               )

      assert %{pan: ["does not match the PAN in the GSTIN (AABCA1234A)"]} = errors_on(changeset)
    end

    test "rejects a state outside the list" do
      assert {:error, changeset} =
               save(%{"company_name" => "Acme", "state" => "Atlantis"}, :general)

      assert %{state: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects a malformed email" do
      assert {:error, changeset} =
               save(%{"company_name" => "Acme", "email" => "not an email"}, :general)

      assert %{email: [_]} = errors_on(changeset)
    end
  end

  describe "invoice section" do
    test "rejects a next number below one" do
      assert {:error, changeset} = save(%{"invoice_next_number" => 0}, :invoice)
      assert %{invoice_next_number: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "a blank prefix resets to the default rather than clearing" do
      # Ecto's cast/4 replaces an empty value with the *field's default* rather
      # than dropping it, so clearing this box resets the prefix to "INV" — it
      # does not keep the previous value and does not leave it blank. That is
      # the behaviour we want for a required setting: the numbering scheme can
      # never end up with no prefix at all.
      {:ok, _} = save(%{"invoice_prefix" => "GST"}, :invoice)
      assert {:ok, organization} = save(%{"invoice_prefix" => ""}, :invoice)

      assert organization.invoice_prefix == "INV"
    end

    test "rejects a prefix with spaces or punctuation" do
      assert {:error, changeset} = save(%{"invoice_prefix" => "IN V!"}, :invoice)
      assert %{invoice_prefix: [_]} = errors_on(changeset)
    end

    test "accepts dashes and slashes, which real numbering uses" do
      assert {:ok, _} = save(%{"invoice_prefix" => "INV-24/25"}, :invoice)
    end
  end

  describe "next_invoice_number/1" do
    test "pads to the configured width" do
      organization = %Organization{
        invoice_prefix: "INV",
        invoice_next_number: 7,
        invoice_number_padding: 4
      }

      assert Settings.next_invoice_number(organization) == "INV-0007"
    end

    test "no padding leaves the number alone" do
      organization = %Organization{
        invoice_prefix: "GST",
        invoice_next_number: 42,
        invoice_number_padding: 0
      }

      assert Settings.next_invoice_number(organization) == "GST-42"
    end

    test "copes with the unsaved defaults" do
      assert Settings.next_invoice_number(%Organization{}) == "INV-0001"
    end
  end

  describe "tax section" do
    test "accepts a statutory slab" do
      for rate <- Organization.gst_rates() do
        assert {:ok, _} = save(%{"default_gst_rate" => rate}, :tax)
      end
    end

    test "rejects a rate that is not a slab" do
      assert {:error, changeset} = save(%{"default_gst_rate" => 7}, :tax)
      assert %{default_gst_rate: [message]} = errors_on(changeset)
      assert message =~ "GST slabs"
    end

    test "toggles save as booleans" do
      assert {:ok, organization} =
               save(%{"cess_enabled" => "true", "composition_scheme" => "false"}, :tax)

      assert organization.cess_enabled == true
      assert organization.composition_scheme == false
    end
  end

  describe "e-way bill section" do
    test "leaves an optional transporter ID alone when blank" do
      assert {:ok, _} = save(%{"ewb_transporter_id" => ""}, :e_way_bill)
    end

    test "validates a transporter ID that is supplied" do
      assert {:error, changeset} = save(%{"ewb_transporter_id" => "NOPE"}, :e_way_bill)
      assert %{ewb_transporter_id: [_]} = errors_on(changeset)

      assert {:ok, _} = save(%{"ewb_transporter_id" => "27AABCA1234A1Z5"}, :e_way_bill)
    end

    test "rejects an unknown transport mode" do
      assert {:error, changeset} = save(%{"ewb_transport_mode" => "Teleport"}, :e_way_bill)
      assert %{ewb_transport_mode: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "notifications section" do
    test "bounds the reminder lead time" do
      assert {:error, changeset} = save(%{"reminder_lead_days" => 0}, :notifications)
      assert %{reminder_lead_days: [_]} = errors_on(changeset)

      assert {:error, changeset} = save(%{"reminder_lead_days" => 90}, :notifications)
      assert %{reminder_lead_days: [_]} = errors_on(changeset)

      assert {:ok, _} = save(%{"reminder_lead_days" => 14}, :notifications)
    end
  end

  describe "preferences section" do
    test "rejects a rows-per-page outside the offered options" do
      assert {:error, changeset} = save(%{"rows_per_page" => 7}, :preferences)
      assert %{rows_per_page: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "financial_years/3" do
    test "is generated around the given day, newest first" do
      years = Settings.financial_years(~D[2026-07-31])

      assert hd(years) == "2027-28 (Apr 2027 - Mar 2028)"
      assert "2026-27 (Apr 2026 - Mar 2027)" in years
      assert "2023-24 (Apr 2023 - Mar 2024)" in years
    end

    test "follows the April boundary rather than the calendar year" do
      # 15 Feb 2026 still sits in FY 2025-26.
      years = Settings.financial_years(~D[2026-02-15])

      assert "2025-26 (Apr 2025 - Mar 2026)" in years
    end
  end
end
