defmodule QuantumBilling.Payments.QRCodeTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.QRCode
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  defp invoice(attrs \\ %{}) do
    struct(
      %Invoice{
        invoice_number: "INV-0042",
        invoice_type: "Tax Invoice",
        invoice_date: ~D[2026-03-01],
        client_name: "Acme Corp",
        company_name: "Quantum Billing Tech",
        grand_total: 11_800,
        currency: "INR"
      },
      attrs
    )
  end

  defp configure_upi(attrs) do
    {:ok, organization} =
      Settings.update_section(Settings.get_organization(), attrs, :integrations)

    organization
  end

  describe "generate_svg/2" do
    test "actually returns a QR" do
      # `EQRCode.encode/1` returns the matrix rather than `{:ok, matrix}`, so
      # matching on `{:ok, _}` silently produced an empty string on every call
      # — which is what every QR in the application used to render.
      svg = QRCode.generate_svg("https://example.test/pay/inv_abc")

      assert svg =~ ~r/^<svg/
      assert svg =~ "</svg>"
      refute svg =~ "<?xml"
    end

    test "encodes a signed e-invoice payload" do
      payload = "eyJhbGciOiJSUzI1NiJ9." <> String.duplicate("a", 1_000)

      assert QRCode.generate_svg(payload) =~ ~r/^<svg/
    end

    test "returns nothing, rather than raising, for content it cannot encode" do
      assert QRCode.generate_svg("") == ""
      assert QRCode.generate_svg(nil) == ""
      # Past the format's 2,952-character ceiling.
      assert QRCode.generate_svg(String.duplicate("x", 5_000)) == ""
    end
  end

  describe "upi_uri/2" do
    test "builds a UPI intent from the configured VPA" do
      organization = configure_upi(%{"upi_vpa" => "acme@okhdfcbank", "upi_payee_name" => "Acme"})

      assert {:ok, uri} = QRCode.upi_uri(invoice(), organization)

      assert uri =~ "upi://pay?"
      assert uri =~ "pa=acme%40okhdfcbank"
      assert uri =~ "pn=Acme"
      # Rupees with paise, which is what UPI apps expect.
      assert uri =~ "am=11800.00"
      assert uri =~ "cu=INR"
      assert uri =~ "tr=INV0042"
    end

    test "has no VPA to use when none is configured" do
      assert {:error, :no_upi_id} = QRCode.upi_uri(invoice(), %Organization{})
      refute QRCode.upi_configured?(%Organization{})
      assert QRCode.generate_invoice_upi_qr(invoice(), organization: %Organization{}) == ""
    end

    test "an email address is not a UPI ID, and is refused as one" do
      # The old code used the organisation's contact email as the payee VPA,
      # which produced a QR that every UPI app rejects when scanned.
      refute QRCode.upi_configured?(%Organization{upi_vpa: "billing@company.com"})

      assert {:error, changeset} =
               Settings.update_section(
                 Settings.get_organization(),
                 %{"upi_vpa" => "billing@company.com"},
                 :integrations
               )

      assert [upi_vpa: {message, _opts}] = changeset.errors
      assert message =~ "not an email address"
    end

    test "escapes spaces as %20 rather than +" do
      organization =
        configure_upi(%{"upi_vpa" => "acme@okaxis", "upi_payee_name" => "Acme Exports Ltd"})

      assert {:ok, uri} = QRCode.upi_uri(invoice(), organization)
      assert uri =~ "pn=Acme%20Exports%20Ltd"
      refute uri =~ "+"
    end

    test "omits the amount on an invoice with nothing to collect" do
      organization = configure_upi(%{"upi_vpa" => "acme@okaxis"})

      assert {:ok, uri} = QRCode.upi_uri(invoice(%{grand_total: 0}), organization)
      refute uri =~ "am="
    end
  end

  describe "generate_invoice_upi_qr/2" do
    test "draws the QR once a UPI ID exists" do
      organization = configure_upi(%{"upi_vpa" => "acme@okhdfcbank"})

      svg = QRCode.generate_invoice_upi_qr(invoice(), organization: organization)

      assert svg =~ ~r/^<svg/
      assert QRCode.upi_configured?(organization)
    end
  end
end
