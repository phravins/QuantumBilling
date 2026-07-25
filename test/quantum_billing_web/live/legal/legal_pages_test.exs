defmodule QuantumBillingWeb.LegalPagesTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "public access" do
    test "terms and privacy are reachable while signed out", %{conn: conn} do
      # they are linked from the signed-out auth screens, so gating them would
      # make those links dead ends
      {:ok, _view, terms} = live(conn, ~p"/terms")
      assert terms =~ "Terms of Service"

      {:ok, _view, privacy} = live(conn, ~p"/privacy")
      assert privacy =~ "Privacy Policy"
    end

    test "they do not render the app sidebar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/terms")

      refute html =~ ~s(href="/invoices")
      refute html =~ "Need Help?"
    end
  end

  describe "unreviewed-template safeguards" do
    test "each page carries a visible review notice", %{conn: conn} do
      for path <- [~p"/terms", ~p"/privacy"] do
        {:ok, _view, html} = live(conn, path)

        assert html =~ "Template pending legal review"
        assert html =~ "do not publish as-is"
        assert html =~ "Draft — not yet in effect."
      end
    end

    test "unfilled placeholders are visibly highlighted", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/terms")

      assert html =~ "registered legal entity name"
      # the highlight class is what makes a leftover blank obvious on the page
      assert html =~ "bg-amber-100"
    end
  end

  describe "cross-linking" do
    test "the auth screens link to the real documents, not to #", %{conn: conn} do
      for path <- [~p"/users/register", ~p"/users/log-in"] do
        {:ok, _view, html} = live(conn, path)

        assert html =~ ~s(href="/terms")
        assert html =~ ~s(href="/privacy")
      end
    end

    test "each document links to the other", %{conn: conn} do
      {:ok, _view, terms} = live(conn, ~p"/terms")
      assert terms =~ ~s(href="/privacy")

      {:ok, _view, privacy} = live(conn, ~p"/privacy")
      assert privacy =~ ~s(href="/terms")
    end

    test "signed-out visitors get a link back to sign in", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/terms")

      assert html =~ "Back to sign in"
      assert html =~ ~s(href="/users/log-in")
    end
  end

  describe "when signed in" do
    setup :register_and_log_in_user

    test "the back link points at the dashboard instead", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/terms")

      assert html =~ "Back to dashboard"
      assert html =~ ~s(href="/dashboard")
    end
  end
end
