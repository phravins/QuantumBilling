defmodule QuantumBillingWeb.HsnFinderLiveTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "page" do
    test "renders the header and both tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/hsn-finder")

      assert html =~ "HSN / SAC Code &amp; GST Rate Finder"
      assert html =~ "Search by Keyword"
      assert html =~ "Search by HSN / SAC Code"
    end

    # There is no side rail any more: the standing guidance moved into the
    # header popover, and Quick Links was removed outright so the search gets
    # the full width of the page.
    test "keeps its guidance in the header popover, not a rail", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/hsn-finder")

      assert has_element?(view, ~s(span[role="button"][aria-label="About HSN / SAC codes"]))
      assert html =~ "About HSN / SAC"
      assert html =~ "Note"

      refute html =~ "Quick Links"
      refute html =~ "https://www.gst.gov.in"
    end

    test "opens with no query and a neutral prompt, not an empty-state warning", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/hsn-finder")

      assert html =~ "Enter a search above"
      refute html =~ "No match in this reference set"
    end

    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/hsn-finder")
    end
  end

  describe "search by keyword" do
    test "a plain-language term reaches a formally-worded entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      html = view |> form("#hsn-search", %{"q" => "laptop"}) |> render_change()

      assert html =~ "8471"
      assert html =~ "1 Result Found"
      # A single match auto-expands into the detail panel.
      assert html =~ "GST Rate"
      assert html =~ "18%"
    end

    test "matches the same code by its ordinary name too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      html = view |> form("#hsn-search", %{"q" => "computer"}) |> render_change()

      assert html =~ "8471"
    end

    test "surfaces the current, post-reform rate for a category that changed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      html = view |> form("#hsn-search", %{"q" => "restaurant"}) |> render_change()

      assert html =~ "9963"
      assert html =~ "18%"
    end

    test "an unmatched keyword shows the honest empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      html = view |> form("#hsn-search", %{"q" => "xyzabc123nonsense"}) |> render_change()

      assert html =~ "No match in this reference set"
      assert html =~ "curated set"
    end

    test "selecting one of several results shows its detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      # "tobacco" reaches both the cigarettes and pan masala entries — a
      # genuine multi-result case, unlike "car" which turned out to also
      # substring-match "carbonated" and "healthcare" via the keyword list.
      html = view |> form("#hsn-search", %{"q" => "tobacco"}) |> render_change()
      assert html =~ "2 Results Found"
      refute html =~ "Effective From"

      selected =
        view
        |> element("button[phx-click=select][phx-value-code='2402']")
        |> render_click()

      assert selected =~ "Effective From"
      assert selected =~ "22 Sep 2025"
    end
  end

  describe "search by code" do
    test "switching tabs clears the previous search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      view |> form("#hsn-search", %{"q" => "laptop"}) |> render_change()

      html =
        view
        |> element("button[phx-click=switch_tab][phx-value-tab=code]")
        |> render_click()

      # Not `refute html =~ "8471"` — the code tab's own placeholder reads
      # "e.g., 8471", so that bare digit string is on screen either way. The
      # actual result content is what must be gone.
      refute html =~ "Automatic data processing machines"
      assert html =~ "Enter a search above"
    end

    test "an exact code reaches the entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      view
      |> element("button[phx-click=switch_tab][phx-value-tab=code]")
      |> render_click()

      html = view |> form("#hsn-search", %{"q" => "8471"}) |> render_change()

      assert html =~ "8471"
      assert html =~ "18%"
    end

    test "a prefix reaches multiple entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hsn-finder")

      view
      |> element("button[phx-click=switch_tab][phx-value-tab=code]")
      |> render_click()

      html = view |> form("#hsn-search", %{"q" => "84"}) |> render_change()

      assert html =~ "Result"
      refute html =~ "No match in this reference set"
    end
  end
end
