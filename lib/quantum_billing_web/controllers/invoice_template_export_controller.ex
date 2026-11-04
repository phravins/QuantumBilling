defmodule QuantumBillingWeb.InvoiceTemplateExportController do
  @moduledoc """
  Downloads an invoice design as its layout XML.

  The file is the same XML the design pad saves, so it can be imported again
  through Settings › Customization › Import — into this company or another.
  The template is looked up inside the current business's schema, so another
  company's id is simply not found.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Layout

  def export(conn, %{"id" => id}) do
    with {int_id, ""} <- Integer.parse(id),
         %{} = template <- Templates.get_template(int_id) do
      xml = template |> Templates.document_of() |> Layout.to_xml()

      send_download(conn, {:binary, xml},
        filename: filename(template.name),
        content_type: "application/xml"
      )
    else
      _not_found ->
        conn
        |> put_flash(:error, "That design does not exist.")
        |> redirect(to: ~p"/settings/customization")
    end
  end

  defp filename(name) do
    slug =
      (name || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    if slug == "", do: "invoice-design.xml", else: "#{slug}.xml"
  end
end
