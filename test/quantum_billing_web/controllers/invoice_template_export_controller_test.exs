defmodule QuantumBillingWeb.InvoiceTemplateExportControllerTest do
  use QuantumBillingWeb.ConnCase, async: false

  alias QuantumBilling.Businesses
  alias QuantumBilling.Repo
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Layout

  describe "signed in" do
    setup :register_and_log_in_user

    test "downloads the design as XML that imports again", %{conn: conn} do
      {:ok, template} = Templates.create_from_preset("modern")

      conn = get(conn, ~p"/invoice-templates/#{template.id}/export")

      assert response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/xml"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="modern.xml")

      assert Layout.parse!(conn.resp_body) == Templates.document_of(template)
    end

    test "an unknown or malformed id goes back to Customization", %{conn: conn} do
      assert conn |> get(~p"/invoice-templates/999999/export") |> redirected_to() ==
               ~p"/settings/customization"

      assert conn |> get("/invoice-templates/abc/export") |> redirected_to() ==
               ~p"/settings/customization"
    end

    # Ids repeat across businesses (each has its own table), so the check is
    # that their design never comes out, whatever this business has at that id.
    test "another business's design never comes out", %{conn: conn} do
      owner = QuantumBilling.AccountsFixtures.owner_fixture()
      {:ok, other} = Businesses.create(owner, %{"name" => "Firm Two"})

      theirs =
        Repo.with_business(other, fn ->
          doc = QuantumBillingWeb.InvoiceDoc.Catalog.classic()
          doc = %{doc | page: %{doc.page | watermark: "custom", watermark_text: "FIRMTWOSECRET"}}
          {:ok, template} = Templates.create_from_document(doc, "Theirs")
          template
        end)

      conn = get(conn, ~p"/invoice-templates/#{theirs.id}/export")

      refute conn.resp_body =~ "FIRMTWOSECRET"
    end
  end

  test "signed out is forbidden", %{conn: conn} do
    assert conn |> get(~p"/invoice-templates/1/export") |> html_response(403) =~
             "forbidden-illustration"
  end
end
