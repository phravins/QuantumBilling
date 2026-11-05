defmodule QuantumBillingWeb.InvoiceTemplateExportController do
  @moduledoc """
  Downloads a design's layout XML, which can be imported again elsewhere.
  Looked up in the current business, so other companies' ids are not found.
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
