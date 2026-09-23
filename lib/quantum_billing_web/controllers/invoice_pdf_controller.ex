defmodule QuantumBillingWeb.InvoicePdfController do
  @moduledoc """
  The invoice as a document: a printable page, and a PDF download.

  `show/2` renders the standalone print-styled page — the browser's own "Save
  as PDF" works from it, and it needs nothing installed on the server.

  `download/2` returns an actual PDF file, printed server-side by
  `QuantumBillingWeb.InvoiceDoc.PDF`. Where no headless browser is installed it
  redirects to the print view and says so, rather than sending something that
  is not a PDF — which is what the mail attachment used to do.

  `public/2` is the same document for a customer, addressed by the invoice's
  public token rather than its id. The public payment page used to link to the
  signed-in route, so "Download PDF" sent the customer to a login screen for an
  application they have no account on.

  `sample/2` and `sample_download/2` are the same two things again for the
  specimen invoice, so a design can be tested at full size and through the real
  printer before it is made the default. They take a design id rather than an
  invoice id: the point is to try a layout, including one that has never been
  issued with.

  Every one of them renders outside the app layout on purpose: the sidebar and
  page chrome have no business on a document going to a client.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDocument
  alias QuantumBillingWeb.InvoicePdfGenerator

  def show(conn, %{"id" => id}) do
    case Invoices.get_invoice(id) do
      nil ->
        conn
        |> put_flash(:error, "That invoice does not exist.")
        |> redirect(to: ~p"/invoices")

      invoice ->
        # The same layout `InvoiceShowLive` resolves, rendered by the same
        # component, so the printed document and the one on screen cannot
        # disagree about what appears on them.
        {doc, accent, logo} = Templates.document_for(invoice)

        conn
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:show,
          invoice: invoice,
          doc: doc,
          accent: accent,
          logo: logo,
          auto_print: true
        )
    end
  end

  def download(conn, %{"id" => id}) do
    case Invoices.get_invoice(id) do
      nil ->
        conn
        |> put_flash(:error, "That invoice does not exist.")
        |> redirect(to: ~p"/invoices")

      invoice ->
        case InvoicePdfGenerator.generate_pdf(invoice) do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: "#{invoice.invoice_number || "invoice"}.pdf",
              content_type: "application/pdf"
            )

          {:error, :no_renderer} ->
            conn
            |> put_flash(
              :info,
              "Server-side PDF export is not available here — use your browser's " <>
                "Print › Save as PDF on this page."
            )
            |> redirect(to: ~p"/invoices/#{invoice.id}/pdf")

          {:error, reason} ->
            conn
            |> put_flash(:error, "That PDF could not be produced (#{inspect(reason)}).")
            |> redirect(to: ~p"/invoices/#{invoice.id}/pdf")
        end
    end
  end

  def public(conn, %{"token" => token}) do
    case Invoices.get_invoice_by_token(token) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: QuantumBillingWeb.ErrorHTML)
        |> put_root_layout(false)
        |> put_layout(false)
        |> render(:"404")

      invoice ->
        case InvoicePdfGenerator.generate_pdf(invoice) do
          {:ok, pdf} ->
            send_download(conn, {:binary, pdf},
              filename: "#{invoice.invoice_number || "invoice"}.pdf",
              content_type: "application/pdf"
            )

          {:error, _reason} ->
            # No renderer here: hand over the print-styled page, which the
            # customer's own browser can save as a PDF.
            conn
            |> put_root_layout(false)
            |> put_layout(false)
            |> render(:show,
              invoice: invoice,
              doc: elem(Templates.document_for(invoice), 0),
              accent: elem(Templates.document_for(invoice), 1),
              logo: elem(Templates.document_for(invoice), 2),
              auto_print: true
            )
        end
    end
  end

  @doc """
  The specimen invoice as a full-size printable page, for testing a design.

  `?template=<id>` picks the design; without one it renders whatever new
  invoices would currently use, which is the reading most people want — "show
  me what my invoices look like".
  """
  def sample(conn, params) do
    invoice = sample_invoice(params["template"])
    {doc, accent, logo} = Templates.document_for(invoice)

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:show, invoice: invoice, doc: doc, accent: accent, logo: logo, auto_print: false)
  end

  @doc """
  The specimen invoice printed to a PDF, by the same printer that prints real
  ones.

  This is the part of a design that cannot be checked on screen: the browser
  preview and the headless printer disagree about page breaks, about web fonts
  and about anything positioned off the edge of the sheet. Falling back to the
  preview page where no renderer is installed keeps the button honest rather
  than sending an error.
  """
  def sample_download(conn, params) do
    invoice = sample_invoice(params["template"])
    back = sample_path(params["template"])

    case InvoicePdfGenerator.generate_pdf(invoice) do
      {:ok, pdf} ->
        send_download(conn, {:binary, pdf},
          filename: "test-invoice.pdf",
          content_type: "application/pdf"
        )

      {:error, :no_renderer} ->
        conn
        |> put_flash(
          :info,
          "Server-side PDF export is not available here — use your browser's " <>
            "Print › Save as PDF on this page."
        )
        |> redirect(to: back)

      {:error, reason} ->
        conn
        |> put_flash(:error, "That PDF could not be produced (#{inspect(reason)}).")
        |> redirect(to: back)
    end
  end

  # The specimen, carrying the real organisation and pointed at one design.
  #
  # `template_id` is set rather than the layout being resolved here, so the
  # sample goes through exactly the same resolution as a real invoice: an id
  # that no longer exists falls back to the default design instead of raising.
  #
  # Digits only. The ids are integers, and `Repo.get` raises `Ecto.Query.CastError`
  # on anything else — a query string is a place a stranger can type, and a
  # crash is not the answer to `?template=nonsense`.
  defp sample_invoice(template_id) do
    invoice = InvoiceDocument.sample(Settings.get_organization())

    case template_id do
      <<digit, _::binary>> = id when digit in ?0..?9 ->
        if String.match?(id, ~r/^\d+$/), do: %{invoice | template_id: id}, else: invoice

      _not_an_id ->
        invoice
    end
  end

  # Back to the preview of the same design, so a fallback does not silently
  # switch which layout is on screen.
  defp sample_path(id) when is_binary(id) and id != "",
    do: ~p"/settings/customization/sample?template=#{id}"

  defp sample_path(_none), do: ~p"/settings/customization/sample"
end
