defmodule QuantumBillingWeb.PublicQuotationLiveTest do
  @moduledoc """
  The client's page for a quotation, `/q/:slug/:token`: no account, the token
  is the access. The client can accept or decline while it is open.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import QuantumBilling.QuotationsFixtures

  alias QuantumBilling.Audit
  alias QuantumBilling.Quotations
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBillingWeb.PublicQuotationLive

  @actor [via: "test"]

  setup do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"company_name" => "ABC Solutions Private Limited", "state" => "Maharashtra (27)"},
        :general
      )

    %{quotation: quotation_fixture(@actor)}
  end

  defp expire!(quotation) do
    today = Quotations.today()

    quotation
    |> Ecto.Changeset.change(
      quotation_date: Date.add(today, -40),
      valid_until: Date.add(today, -1)
    )
    |> Repo.update!()
  end

  test "shows the quotation with both answers", %{conn: conn, quotation: quotation} do
    {:ok, view, html} = live(conn, PublicQuotationLive.path(quotation.public_token))

    assert html =~ quotation.number
    assert has_element?(view, "#public-accept-quotation")
    assert has_element?(view, "#public-decline-quotation")
    assert has_element?(view, "#public-quotation-pdf")
    refute has_element?(view, "#public-quotation-accepted")
  end

  test "formats quotation dates in the header", %{conn: conn, quotation: quotation} do
    quotation =
      quotation
      |> Ecto.Changeset.change(
        quotation_date: ~D[2026-11-21],
        valid_until: ~D[2026-12-21]
      )
      |> Repo.update!()

    {:ok, _view, html} = live(conn, PublicQuotationLive.path(quotation.public_token))

    assert html =~ "Dated 21 Nov 2026 · Valid until 21 Dec 2026"
  end

  test "accepting records the client's answer", %{conn: conn, quotation: quotation} do
    {:ok, view, _html} = live(conn, PublicQuotationLive.path(quotation.public_token))

    view |> element("#public-accept-quotation") |> render_click()

    assert has_element?(view, "#public-quotation-accepted")
    refute has_element?(view, "#public-accept-quotation")
    refute has_element?(view, "#public-decline-quotation")
    assert Quotations.get_quotation(quotation.id).status == "Accepted"

    assert Enum.any?(Audit.list_audit_logs(), fn log ->
             log.action == "quotation_accepted" and log.resource_id == to_string(quotation.id) and
               is_nil(log.user_id)
           end)
  end

  test "declining records the client's answer", %{conn: conn, quotation: quotation} do
    {:ok, view, _html} = live(conn, PublicQuotationLive.path(quotation.public_token))

    view |> element("#public-decline-quotation") |> render_click()

    assert has_element?(view, "#public-quotation-status", "Declined")
    refute has_element?(view, "#public-accept-quotation")
    assert Quotations.get_quotation(quotation.id).status == "Declined"
  end

  test "an answer given elsewhere since the page opened is not overwritten",
       %{conn: conn, quotation: quotation} do
    {:ok, view, _html} = live(conn, PublicQuotationLive.path(quotation.public_token))
    {:ok, _declined} = Quotations.decline(@actor, quotation)

    render_click(view, "accept", %{"revision" => to_string(quotation.revision)})

    assert has_element?(view, "#public-quotation-error")
    assert has_element?(view, "#public-quotation-status", "Declined")
    assert Quotations.get_quotation(quotation.id).status == "Declined"
  end

  test "an answer from an older quotation revision is refused",
       %{conn: conn, quotation: quotation} do
    {:ok, view, _html} = live(conn, PublicQuotationLive.path(quotation.public_token))
    Repo.update!(
      Ecto.Changeset.change(quotation, remarks: "Revised", revision: quotation.revision + 1)
    )

    view |> element("#public-accept-quotation") |> render_click()

    assert has_element?(view, "#public-quotation-error")
    assert render(view) =~ "Revision 2"
    assert Quotations.get_quotation(quotation.id).status == "Draft"
  end

  test "an open page receives edits and refreshes to the new revision", %{conn: conn, quotation: quotation} do
    {:ok, view, _html} = live(conn, PublicQuotationLive.path(quotation.public_token))

    {:ok, updated} = Quotations.update_quotation(@actor, quotation, %{"remarks" => "New terms"})

    assert updated.revision == quotation.revision + 1
    assert has_element?(view, "#public-quotation-error", "This quotation changed")
    assert render(view) =~ "Revision 2"
  end

  test "an expired quotation can't be answered", %{conn: conn, quotation: quotation} do
    quotation = expire!(quotation)
    {:ok, view, _html} = live(conn, PublicQuotationLive.path(quotation.public_token))

    assert has_element?(view, "#public-quotation-expired")
    refute has_element?(view, "#public-accept-quotation")
    refute has_element?(view, "#public-decline-quotation")
  end

  test "an unknown token sends the visitor away", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             live(conn, PublicQuotationLive.path("not-a-real-token"))

    assert flash["error"] =~ "Invalid"
  end

  test "a quotation in the Bin no longer opens", %{conn: conn, quotation: quotation} do
    {:ok, _} = Quotations.delete_quotation(@actor, quotation)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn, PublicQuotationLive.path(quotation.public_token))
  end

  describe "the PDF" do
    test "downloads without an account", %{conn: conn, quotation: quotation} do
      conn = get(conn, PublicQuotationLive.path(quotation.public_token) <> "/pdf")
      assert conn.status == 200
    end

    test "an unknown token is not found", %{conn: conn} do
      conn = get(conn, PublicQuotationLive.path("not-a-real-token") <> "/pdf")
      assert conn.status == 404
    end
  end
end
