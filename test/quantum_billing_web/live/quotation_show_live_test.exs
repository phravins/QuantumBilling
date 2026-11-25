defmodule QuantumBillingWeb.QuotationShowLiveTest do
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.CustomFieldsFixtures, only: [field_fixture: 2]
  import QuantumBilling.QuotationsFixtures

  alias QuantumBilling.Invoices
  alias QuantumBilling.Quotations
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  setup do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "ABC Solutions Private Limited",
          "gstin" => "27AABCA1234A1Z5",
          "pan" => "AABCA1234A",
          "state" => "Maharashtra (27)"
        },
        :general
      )

    :ok
  end

  defp status(view), do: view |> element("#quotation-status") |> render()

  defp convert(quotation) do
    params =
      quotation
      |> Quotations.invoice_params()
      |> Map.put("invoice_date", Date.to_iso8601(Quotations.today()))

    {:ok, invoice} = Invoices.create_invoice(params, quotation_id: quotation.id)
    invoice
  end

  describe "workflow" do
    test "a draft can be sent, then accepted, and only then converted",
         %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      assert status(view) =~ ~s(data-status="Draft")
      assert has_element?(view, "#quotation-document")
      assert has_element?(view, "#edit-quotation")
      refute has_element?(view, "#convert-to-invoice")

      view |> element("#mark-sent") |> render_click()
      assert status(view) =~ ~s(data-status="Sent")
      refute has_element?(view, "#mark-sent")
      refute has_element?(view, "#convert-to-invoice")

      view |> element("#accept-quotation") |> render_click()
      assert status(view) =~ ~s(data-status="Accepted")
      refute has_element?(view, "#quotation-workflow")
      refute has_element?(view, "#edit-quotation")

      assert view |> element("#convert-to-invoice") |> render() =~
               "/invoices/new?quotation=#{quotation.id}"
    end

    test "a declined quotation is locked and can't be converted", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      view |> element("#decline-quotation") |> render_click()

      assert status(view) =~ ~s(data-status="Declined")
      refute has_element?(view, "#edit-quotation")
      refute has_element?(view, "#convert-to-invoice")
    end

    test "a converted quotation links its invoice and can't be converted again",
         %{conn: conn, scope: scope} do
      quotation = accepted_quotation_fixture(scope)
      invoice = convert(quotation)

      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      assert has_element?(view, "#converted-invoice", invoice.invoice_number)
      refute has_element?(view, "#convert-to-invoice")
      refute has_element?(view, "#delete-quotation")
    end

    test "delete returns to the list", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      assert {:error, {:live_redirect, %{to: "/quotations"}}} =
               view |> element("#delete-quotation") |> render_click()

      assert Quotations.get_quotation(quotation.id) == nil
      assert Quotations.get_deleted_quotation(quotation.id)
    end
  end

  describe "sharing" do
    test "shows a new quotation's client link", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      assert has_element?(view, "#quotation-public-url", quotation.public_token)
      assert has_element?(view, "#quotation-public-link")
      refute has_element?(view, "#create-public-link")
    end

    test "makes a link for a quotation saved before links existed", %{conn: conn, scope: scope} do
      quotation =
        scope |> quotation_fixture() |> Ecto.Changeset.change(public_token: nil) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      refute has_element?(view, "#quotation-public-url")
      view |> element("#create-public-link") |> render_click()

      token = Quotations.get_quotation(quotation.id).public_token
      assert has_element?(view, "#quotation-public-url", token)
      refute has_element?(view, "#create-public-link")
    end

    test "emails the quotation and marks a draft Sent", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      view
      |> form("#quotation-email-form", %{"email" => %{"to" => "buyer@acme.test"}})
      |> render_submit()

      assert has_element?(view, "#flash-info", "buyer@acme.test")
      assert status(view) =~ ~s(data-status="Sent")
      assert has_element?(view, "#quotation-public-url")

      assert_received {:email,
                       %Swoosh.Email{subject: "Quotation " <> _, to: [{_, "buyer@acme.test"}]}}
    end

    test "refuses a bad address and leaves the draft alone", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      view
      |> form("#quotation-email-form", %{"email" => %{"to" => "not-an-address"}})
      |> render_submit()

      assert has_element?(view, "#flash-error", "valid email")
      assert status(view) =~ ~s(data-status="Draft")
    end
  end

  describe "custom fields" do
    test "shows the values a quotation was saved with", %{conn: conn, scope: scope} do
      field_fixture("quotation", %{"label" => "Project code", "type" => "text"})
      quotation = quotation_fixture(scope, %{"custom_fields" => %{"project_code" => "PRJ-7"}})

      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      assert has_element?(view, "#quotation-custom-values", "PRJ-7")
    end

    test "has no details card without values", %{conn: conn, scope: scope} do
      field_fixture("quotation", %{"label" => "Project code", "type" => "text"})
      quotation = quotation_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      refute has_element?(view, "#quotation-custom-fields")
    end
  end

  describe "converting through the invoice form" do
    test "opens pre-filled, and saving links the invoice", %{conn: conn, scope: scope} do
      quotation = accepted_quotation_fixture(scope, %{"client_name" => "Bluewave Retail"})

      {:ok, view, _html} = live(conn, ~p"/quotations/#{quotation}")

      {:ok, view, _html} =
        view |> element("#convert-to-invoice") |> render_click() |> follow_redirect(conn)

      assert has_element?(view, "#from-quotation-banner", quotation.number)

      assert has_element?(
               view,
               ~s(#invoice-form [name="invoice[client_name]"][value="Bluewave Retail"])
             )

      assert has_element?(
               view,
               ~s(#invoice-form [name="invoice[items][0][description]"][value="Web Development Services"])
             )

      assert {:error, {:live_redirect, %{to: path}}} =
               view |> form("#invoice-form") |> render_submit()

      invoice = Quotations.get_quotation(quotation.id).invoice
      assert path == "/invoices/#{invoice.id}"
      assert invoice.quotation_id == quotation.id
      assert invoice.grand_total == quotation.grand_total

      {:ok, show, _html} = live(conn, path)
      assert has_element?(show, "#invoice-quotation-link", quotation.number)
    end

    test "an already-converted quotation goes back to its page", %{conn: conn, scope: scope} do
      quotation = accepted_quotation_fixture(scope)
      convert(quotation)
      path = "/quotations/#{quotation.id}"

      assert {:error, {:live_redirect, %{to: ^path, flash: %{"error" => message}}}} =
               live(conn, ~p"/invoices/new?#{[quotation: quotation.id]}")

      assert message =~ "already converted"
    end

    test "a quotation that isn't accepted goes back to its page", %{conn: conn, scope: scope} do
      quotation = quotation_fixture(scope)
      path = "/quotations/#{quotation.id}"

      assert {:error, {:live_redirect, %{to: ^path}}} =
               live(conn, ~p"/invoices/new?#{[quotation: quotation.id]}")
    end
  end

  describe "print page" do
    test "is titled Quotation with its validity and no payment block",
         %{conn: conn, scope: scope} do
      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{"upi_vpa" => "abcsolutions@okhdfc", "upi_payee_name" => "ABC Solutions"},
          :integrations
        )

      quotation = quotation_fixture(scope)
      html = conn |> get(~p"/quotations/#{quotation}/pdf") |> html_response(200)

      assert html =~ "Quotation"
      assert html =~ "Valid Until"
      assert html =~ quotation.number
      refute html =~ "abcsolutions@okhdfc"
      refute html =~ ~s(class="qb-doc__payment")
    end

    test "an unknown quotation goes back to the list", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/quotations/0/pdf")) == "/quotations"
    end
  end
end
