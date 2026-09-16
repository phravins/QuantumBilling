defmodule QuantumBillingWeb.InvoiceDocumentPdfTest do
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.InvoiceDoc.PDF
  alias QuantumBillingWeb.InvoicePdfGenerator

  @uploads Path.join([:code.priv_dir(:quantum_billing), "static", "uploads"])

  # A 1×1 PNG, so the logo under test is a real image file.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  defp invoice(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-9001-#{System.unique_integer([:positive])}",
          invoice_type: "Tax Invoice",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          company_name: "Quantum Billing Tech",
          client_name: "Acme Corp",
          taxable_value: 10_000,
          cgst_amount: 900,
          sgst_amount: 900,
          grand_total: 11_800
        },
        attrs
      )
    )
  end

  defp with_logo(fun) do
    File.mkdir_p!(@uploads)
    name = "test-logo-#{System.unique_integer([:positive])}.png"
    File.write!(Path.join(@uploads, name), @png)

    {:ok, _organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{"doc_logo_path" => "/uploads/#{name}"},
        :customization
      )

    try do
      fun.("/uploads/#{name}")
    after
      File.rm(Path.join(@uploads, name))
    end
  end

  describe "generate_html/2" do
    test "carries the stylesheet and the invoice's own figures" do
      html = InvoicePdfGenerator.generate_html(invoice())

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "Acme Corp"
      assert html =~ "<style"
    end

    test "leaves the print button out of a document meant for attaching" do
      assert InvoicePdfGenerator.generate_html(invoice()) =~ "Print / Save as PDF"

      refute InvoicePdfGenerator.generate_html(invoice(), print_button: false) =~
               "Print / Save as PDF"
    end

    test "inlines the logo so it survives leaving the server" do
      with_logo(fn _path ->
        html = InvoicePdfGenerator.generate_html(invoice())

        # `/uploads/logo.png` resolves only against the running app, so in an
        # emailed document or a locally printed page it was a broken image and
        # the customisation looked like it had not applied.
        assert html =~ "data:image/png;base64,"
        refute html =~ ~s(src="/uploads/)
      end)
    end
  end

  describe "inline_logo/1" do
    test "passes through what it cannot or should not inline" do
      assert InvoicePdfGenerator.inline_logo(nil) == nil

      assert InvoicePdfGenerator.inline_logo("https://cdn.example.test/logo.png") ==
               "https://cdn.example.test/logo.png"

      # Missing file: the document still has to render.
      assert InvoicePdfGenerator.inline_logo("/uploads/does-not-exist.png") ==
               "/uploads/does-not-exist.png"
    end
  end

  describe "generate_pdf/2" do
    test "produces a real PDF when a browser is available, or says why not" do
      case PDF.executable() do
        nil ->
          # The attachment path is what matters then, and it is covered below.
          assert {:error, :no_renderer} = InvoicePdfGenerator.generate_pdf(invoice())

        _binary ->
          assert {:ok, pdf} = InvoicePdfGenerator.generate_pdf(invoice())
          # It used to return the HTML string, which the mailer attached as
          # `.pdf`; this is the check that catches that regression.
          assert <<"%PDF-", _rest::binary>> = pdf
          assert byte_size(pdf) > 1_000
      end
    end

    test "reports a missing renderer rather than inventing one" do
      previous_config = Application.get_env(:quantum_billing, :pdf_chrome_path)
      previous_env = System.get_env("PDF_CHROME_PATH")

      Application.put_env(:quantum_billing, :pdf_chrome_path, "/nonexistent/chrome")
      System.put_env("PDF_CHROME_PATH", "/nonexistent/chrome")

      on_exit(fn ->
        # Restored rather than deleted: this environment variable is global, and
        # wiping it would leave every later test in the run without a renderer.
        if previous_env,
          do: System.put_env("PDF_CHROME_PATH", previous_env),
          else: System.delete_env("PDF_CHROME_PATH")

        if previous_config,
          do: Application.put_env(:quantum_billing, :pdf_chrome_path, previous_config),
          else: Application.delete_env(:quantum_billing, :pdf_chrome_path)
      end)

      refute PDF.available?()
      assert {:error, :no_renderer} = InvoicePdfGenerator.generate_pdf(invoice())
    end
  end

  describe "the email attachment" do
    test "is a PDF when one can be printed, and honest HTML when it cannot" do
      invoice = invoice()

      {:ok, email} = QuantumBilling.InvoiceNotifier.build_email("client@example.com", invoice)

      assert [attachment] = email.attachments

      case PDF.executable() do
        nil ->
          # Named and typed for what it actually is. The bug being guarded
          # against is an HTML file called `INV-1234.pdf`.
          assert attachment.filename == "#{invoice.invoice_number}.html"
          assert attachment.content_type == "text/html"

        _binary ->
          assert attachment.filename == "#{invoice.invoice_number}.pdf"
          assert attachment.content_type == "application/pdf"
      end
    end
  end
end
