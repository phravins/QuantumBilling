defmodule QuantumBillingWeb.InvoiceDocumentZatcaTest do
  @moduledoc """
  ZATCA Phase 1 end to end: a Saudi business's invoices carry the bilingual
  title, the Arabic seller details and the QR code on every surface, its
  Settings take the Arabic fields, and nothing changes for anyone else.
  """
  # Not async: concurrent default-template seeders deadlock (see InvoiceDocumentTest).
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.DataCase, only: [errors_on: 1]

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Backup
  alias QuantumBilling.Businesses
  alias QuantumBilling.Invoices
  alias QuantumBilling.QuotationsFixtures
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Tax
  alias QuantumBilling.TaxRates
  alias QuantumBilling.Templates
  alias QuantumBilling.Zatca
  alias QuantumBilling.Zatca.TLV
  alias QuantumBillingWeb.InvoicePdfGenerator

  @vat_number "310122393500003"
  @buyer_vat "300000000000003"
  @name_ar "شركة ماثل التجريبية"
  @address_ar "الرياض"

  setup :register_and_log_in_owner

  setup %{user: user} do
    business = Businesses.default!()

    owner =
      Scope.put_membership(Scope.for_user(user), Businesses.get_membership(user, business.id))

    %{owner: owner}
  end

  defp both(conn, invoice) do
    {:ok, _view, screen} = live(conn, ~p"/invoices/#{invoice.id}")
    printed = conn |> get(~p"/invoices/#{invoice.id}/pdf") |> html_response(200)
    [{"screen", screen}, {"printed", printed}]
  end

  defp document(html), do: html |> LazyHTML.from_document() |> LazyHTML.query(".qb-doc")

  defp texts(html, selector) do
    html
    |> document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp present?(html, selector), do: texts(html, selector) != []

  describe "a Saudi VAT business billing in SAR" do
    setup %{owner: owner} do
      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{"tax_regime" => "vat", "vat_country" => "SA", "vat_number" => @vat_number},
          :tax
        )

      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{
            "company_name" => "Bobs Records",
            "currency" => "SAR - Saudi Riyal",
            "company_name_ar" => @name_ar,
            "address_ar" => @address_ar
          },
          :general
        )

      {:ok, _rates} = TaxRates.ensure_presets(owner, "SA")
      :ok
    end

    defp rate_id do
      TaxRates.list_rates() |> Enum.find(&(&1.name == "Standard 15%")) |> Map.fetch!(:id)
    end

    defp line do
      %{
        "description" => "Vinyl records",
        "quantity" => "1",
        "unit" => "Nos",
        "rate" => "1000",
        "tax_rate_id" => to_string(rate_id())
      }
    end

    defp invoice!(attrs \\ %{}) do
      {:ok, invoice} =
        %{
          "invoice_date" => "2026-11-27",
          "client_name" => "Walk-in customer",
          "items" => %{"0" => line()}
        }
        |> Map.merge(attrs)
        |> Invoices.create_invoice()

      invoice
    end

    test "a simplified invoice prints the ZATCA title, the Arabic seller and the QR code",
         %{conn: conn} do
      invoice = invoice!()

      for {label, html} <- both(conn, invoice) do
        assert present?(html, "#zatca-qr svg"), label

        assert [heading] = texts(html, ".qb-doc__heading"), label
        assert heading =~ "Simplified Tax Invoice", label
        assert heading =~ "فاتورة ضريبية مبسطة", label

        assert texts(html, "#company-name-ar") == [@name_ar], label
        assert present?(html, "[lang=ar]"), label

        # A simplified invoice keeps the usual columns.
        headers = texts(html, ".qb-doc__items:not(.qb-doc__vat-summary) thead th")
        refute Enum.any?(headers, &(&1 =~ "VAT amount")), label
      end
    end

    test "the QR code holds the issued invoice's seller, totals and time" do
      invoice = invoice!()

      assert {:ok, tags} = invoice |> Zatca.qr_payload() |> Base.decode64!() |> TLV.decode()

      assert [
               {1, @name_ar},
               {2, @vat_number},
               {3, timestamp},
               {4, "1150.00"},
               {5, "150.00"}
             ] = tags

      assert timestamp =~ ~r/^2026-11-2[67]T\d{2}:\d{2}:\d{2}Z$/
    end

    test "a buyer with a VAT number gets a Tax Invoice with each line's VAT and total",
         %{conn: conn} do
      invoice = invoice!(%{"client_tax_number" => @buyer_vat})

      for {label, html} <- both(conn, invoice) do
        assert present?(html, "#zatca-qr svg"), label

        assert [heading] = texts(html, ".qb-doc__heading"), label
        assert heading =~ "Tax Invoice", label
        assert heading =~ "فاتورة ضريبية", label
        refute heading =~ "Simplified", label

        headers = texts(html, ".qb-doc__items:not(.qb-doc__vat-summary) thead th")
        assert Enum.any?(headers, &(&1 =~ "VAT amount")), label
        assert Enum.any?(headers, &(&1 =~ "Total incl. VAT")), label

        rows = texts(html, ".qb-doc__items:not(.qb-doc__vat-summary) tbody tr")
        assert Enum.any?(rows, &(&1 =~ "150.00" and &1 =~ "1,150.00")), label
      end
    end

    test "the Arabic font is linked on screen and inlined in the PDF", %{conn: conn} do
      invoice = invoice!()

      {:ok, _view, screen} = live(conn, ~p"/invoices/#{invoice.id}")
      assert screen =~ "/fonts/noto-sans-arabic-regular.ttf"

      pdf_html = InvoicePdfGenerator.generate_html(invoice)
      assert pdf_html =~ "data:font/ttf;base64,"
      refute pdf_html =~ "/fonts/noto-sans-arabic"

      font = conn |> recycle() |> get("/fonts/noto-sans-arabic-regular.ttf")
      assert font.status == 200
    end

    test "the customer's page carries the QR code" do
      invoice = invoice!()

      {:ok, view, _html} = live(build_conn(), ~p"/pay/#{invoice.public_token}")
      assert has_element?(view, "#zatca-qr svg")
    end

    test "a quotation has no QR code", %{conn: conn, owner: owner} do
      quotation =
        QuotationsFixtures.quotation_fixture(owner, %{
          "place_of_supply" => nil,
          "items" => %{"0" => Map.put(line(), "position", "0")}
        })

      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation.id}")
      refute has_element?(view, "#zatca-qr")
    end

    test "the design pad says what Saudi invoices add", %{conn: conn} do
      template = Templates.ensure_default()

      {:ok, view, _html} = live(conn, ~p"/invoice-templates/#{template.id}")
      assert has_element?(view, "#zatca-design-note")
    end

    test "an issued invoice keeps its Arabic name and QR code when Settings change" do
      invoice = invoice!()

      assert invoice.company_name_ar == @name_ar
      assert invoice.company_address_ar == @address_ar
      assert invoice.company_vat_country == "SA"

      payload = Zatca.qr_payload(invoice)

      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{"company_name_ar" => "اسم جديد"},
          :general
        )

      assert Zatca.qr_payload(Invoices.get_invoice!(invoice.id)) == payload
    end

    test "a backup keeps the Arabic fields and the VAT country" do
      # Hours before the restore, so a restore that reset it would show.
      invoice =
        invoice!()
        |> Ecto.Changeset.change(inserted_at: ~U[2026-01-05 08:15:00Z])
        |> Repo.update!()

      json = Backup.export_json()
      decoded = Jason.decode!(json)

      assert %{"company_name_ar" => @name_ar, "address_ar" => @address_ar} =
               decoded["organization"]

      assert [
               %{
                 "company_name_ar" => @name_ar,
                 "company_address_ar" => @address_ar,
                 "company_vat_country" => "SA"
               }
             ] = decoded["invoices"]

      assert {:ok, _counts} = Backup.restore_json(json)

      restored = Invoices.get_invoice!(invoice.id)
      assert restored.company_name_ar == @name_ar
      assert restored.company_vat_country == "SA"
      assert restored.inserted_at == ~U[2026-01-05 08:15:00Z]
      assert Zatca.qr_payload(restored) == Zatca.qr_payload(invoice)
      assert Settings.get_organization().address_ar == @address_ar
    end

    test "a backup from before ZATCA Phase 1 restores its invoices' VAT country" do
      invoice = invoice!()

      json =
        Backup.export_json()
        |> Jason.decode!()
        |> Map.update!("invoices", fn rows ->
          Enum.map(rows, &Map.delete(&1, "company_vat_country"))
        end)
        |> Jason.encode!()

      assert {:ok, _counts} = Backup.restore_json(json)

      restored = Invoices.get_invoice!(invoice.id)
      assert restored.company_vat_country == "SA"
      assert Zatca.applies?(restored)
    end

    test "Settings take the Arabic name, a five-digit postal code and Riyadh time",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/general")
      assert has_element?(view, "#settings-arabic")

      view
      |> form("#settings-form", %{
        "organization" => %{
          "company_name_ar" => "مؤسسة الاختبار",
          "pincode" => "12345",
          "timezone" => "Asia/Riyadh"
        }
      })
      |> render_submit()

      organization = Settings.get_organization()
      assert organization.company_name_ar == "مؤسسة الاختبار"
      assert organization.pincode == "12345"
      assert organization.timezone == "Asia/Riyadh"
    end

    test "Settings refuse an Arabic name too long for the QR code and a six-digit postal code" do
      # 130 two-byte letters: under the 160-character limit, over the QR's 255 bytes.
      long = String.duplicate("ب", 130)

      assert {:error, changeset} =
               Settings.update_section(
                 Settings.get_organization(),
                 %{"company_name_ar" => long, "pincode" => "123456"},
                 :general
               )

      assert %{
               company_name_ar: ["is too long for the invoice QR code; shorten it"],
               pincode: ["must be five digits"]
             } = errors_on(changeset)
    end

    test "a Saudi VAT number starts and ends with 3" do
      assert Tax.tax_number_valid?("SA", @vat_number)
      refute Tax.tax_number_valid?("SA", "123456789012345")

      assert {:error, changeset} =
               Settings.update_section(
                 Settings.get_organization(),
                 %{"vat_number" => "123456789012345"},
                 :tax
               )

      assert %{vat_number: [_message]} = errors_on(changeset)
    end
  end

  describe "an Indian GST business" do
    test "prints no QR code, no Arabic and no Arabic font", %{conn: conn} do
      {:ok, invoice} =
        Invoices.create_invoice(%{
          "invoice_date" => "2026-11-27",
          "client_name" => "V2V Technologies",
          "place_of_supply" => "Maharashtra (27)",
          "items" => %{
            "0" => %{
              "description" => "Consulting",
              "hsn_sac" => "998313",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "1000",
              "tax_rate" => "18"
            }
          }
        })

      refute invoice.company_vat_country

      for {label, html} <- both(conn, invoice) do
        refute present?(html, "#zatca-qr"), label
        refute present?(html, "[lang=ar]"), label
        refute html =~ "noto-sans-arabic", label
        refute html =~ "data:font/ttf", label
      end
    end

    test "sees no Arabic fields in Settings and no note on the design pad", %{conn: conn} do
      {:ok, settings, _html} = live(conn, ~p"/settings/general")
      refute has_element?(settings, "#settings-arabic")

      template = Templates.ensure_default()
      {:ok, pad, _html} = live(conn, ~p"/invoice-templates/#{template.id}")
      refute has_element?(pad, "#zatca-design-note")
    end
  end
end
