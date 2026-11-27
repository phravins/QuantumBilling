defmodule QuantumBillingWeb.HsnSuggestionsLiveTest do
  @moduledoc """
  Issue #100: HSN/SAC suggestions on the invoice and quotation item rows.
  Each test names the acceptance criterion it covers.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices
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

  defp line(description, over \\ %{}) do
    Map.merge(
      %{
        "description" => description,
        "hsn_sac" => "",
        "quantity" => "1",
        "unit" => "Nos",
        "rate" => "1000",
        "tax_rate" => "18"
      },
      over
    )
  end

  defp params(items, form \\ "invoice") do
    %{
      form => %{
        "invoice_date" => "2026-11-20",
        "quotation_date" => "2026-11-20",
        "valid_until" => "2026-12-20",
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "V2V Technologies",
        "items" => items
      }
    }
  end

  # A change to one field of row `index`, as the browser sends it.
  defp type(view, items, index, field, form \\ "invoice") do
    render_change(
      view,
      "validate",
      Map.put(params(items, form), "_target", [form, "items", to_string(index), field])
    )
  end

  defp panel(index, form \\ "invoice"), do: "##{form}-hsn-panel-#{index}"

  defp option(index, code, form \\ "invoice"),
    do: "#{panel(index, form)} button[phx-value-code=\"#{code}\"]"

  describe "suggestions while typing (criterion 1)" do
    test "a description suggests matching HSN/SAC codes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Office chair")}, 0, "description")

      assert has_element?(view, panel(0))
      assert has_element?(view, option(0, "9401"))
      assert has_element?(view, option(0, "9401"), "HSN finder")
    end

    test "the business's own history comes first", %{conn: conn} do
      {:ok, _invoice} =
        Invoices.create_invoice(%{
          "invoice_date" => "2026-11-01",
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "Earlier Client",
          "items" => %{
            "0" => %{
              "description" => "Ergonomic office chair",
              "hsn_sac" => "940130",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "5000",
              "tax_rate" => "18"
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/invoices/new")
      html = type(view, %{"0" => line("Office chair")}, 0, "description")

      assert has_element?(view, option(0, "940130"), "Used before")

      first =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#{panel(0)} button[data-hsn-option]")
        |> Enum.at(0)
        |> LazyHTML.attribute("phx-value-code")

      assert first == ["940130"]
    end

    test "typing digits in the HSN/SAC box suggests codes under them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Something", %{"hsn_sac" => "94"})}, 0, "hsn_sac")

      assert has_element?(view, option(0, "9401"))
    end

    test "works on a row added after the first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Consulting"), "1" => line("Office chair")}, 1, "description")

      assert has_element?(view, option(1, "9401"))
      refute has_element?(view, panel(0))
    end
  end

  describe "picking (criteria 2 and 4)" do
    test "fills the code and GST rate on that row only, and asks to verify", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")
      items = %{"0" => line("Consulting", %{"tax_rate" => "5"}), "1" => line("Office chair")}

      type(view, items, 1, "description")
      view |> element(option(1, "9401")) |> render_click()

      assert has_element?(view, ~s(input[name="invoice[items][1][hsn_sac]"][value="9401"]))

      assert has_element?(
               view,
               ~s(select[name="invoice[items][1][tax_rate]"] option[value="18"][selected])
             )

      # Row 0 is untouched.
      assert has_element?(view, ~s(input[name="invoice[items][0][hsn_sac]"][value=""]))

      assert has_element?(
               view,
               ~s(select[name="invoice[items][0][tax_rate]"] option[value="5"][selected])
             )

      assert has_element?(view, "#invoice-hsn-suggested-1", "Suggested")

      assert has_element?(
               view,
               ~s(#invoice-hsn-note-1[aria-live="polite"]),
               "Suggested HSN 9401 at 18% — please verify"
             )

      refute has_element?(view, panel(1))
    end

    test "the note goes after a few seconds", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Office chair")}, 0, "description")
      view |> element(option(0, "9401")) |> render_click()
      assert has_element?(view, "#invoice-hsn-note-0", "please verify")
      assert has_element?(view, "#invoice-hsn-row-0", "please verify")

      send(view.pid, {:clear_hsn_notice, "0"})
      refute has_element?(view, "#invoice-hsn-note-0", "please verify")
      refute has_element?(view, "#invoice-hsn-row-0")
    end

    test "editing the code by hand removes the Suggested tag", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Office chair")}, 0, "description")
      view |> element(option(0, "9401")) |> render_click()
      assert has_element?(view, "#invoice-hsn-suggested-0")

      type(view, %{"0" => line("Office chair", %{"hsn_sac" => "9403"})}, 0, "hsn_sac")
      refute has_element?(view, "#invoice-hsn-suggested-0")
    end
  end

  describe "no overwrite without confirmation (criterion 3)" do
    test "a typed code makes picking ask first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Office chair", %{"hsn_sac" => "9403"})}, 0, "hsn_sac")
      type(view, %{"0" => line("Office chair", %{"hsn_sac" => "9403"})}, 0, "description")

      assert has_element?(view, option(0, "9401") <> "[data-confirm]")
    end

    test "a rate changed by hand makes picking ask first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Office chair", %{"tax_rate" => "5"})}, 0, "tax_rate")
      type(view, %{"0" => line("Office chair", %{"tax_rate" => "5"})}, 0, "description")

      assert has_element?(view, option(0, "9401") <> "[data-confirm]")
    end

    test "keeps overwrite confirmation on a manual row when other rows are added or removed",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")
      manual = line("Office chair", %{"tax_rate" => "5"})
      items = %{"0" => line("Consulting"), "1" => manual}

      type(view, items, 1, "tax_rate")

      add =
        items
        |> params()
        |> put_in(["invoice", "items_sort"], ["0", "1", "new"])
        |> Map.put("_target", ["invoice", "items_sort"])

      render_change(view, "validate", add)
      items = Map.put(items, "2", line(""))
      type(view, items, 1, "description")
      assert has_element?(view, option(1, "9401") <> "[data-confirm]")

      remove =
        items
        |> params()
        |> put_in(["invoice", "items_sort"], ["0", "1", "2"])
        |> put_in(["invoice", "items_drop"], ["0"])
        |> Map.put("_target", ["invoice", "items_drop"])

      render_change(view, "validate", remove)
      type(view, %{"0" => manual, "1" => line("Office chair")}, 0, "description")
      assert has_element?(view, option(0, "9401") <> "[data-confirm]")

      type(view, %{"0" => manual, "1" => line("Office chair")}, 1, "description")
      refute has_element?(view, option(1, "9401") <> "[data-confirm]")
    end

    test "an untouched row is filled without asking", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Office chair")}, 0, "description")

      refute has_element?(view, option(0, "9401") <> "[data-confirm]")
    end

    test "a code saved on the invoice makes picking ask first", %{conn: conn} do
      {:ok, invoice} =
        Invoices.create_invoice(%{
          "invoice_date" => "2026-11-01",
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "Earlier Client",
          "items" => %{"0" => line("Consulting", %{"hsn_sac" => "998313"})}
        })

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}/edit")

      # Through form/3, so the row's stored id and order go with it.
      view
      |> form("#invoice-form", %{
        "invoice" => %{"items" => %{"0" => %{"description" => "Office chair"}}}
      })
      |> render_change(%{"_target" => ["invoice", "items", "0", "description"]})

      assert has_element?(view, option(0, "9401") <> "[data-confirm]")
    end
  end

  describe "keyboard" do
    test "the hook is wired on invoices and quotations", %{conn: conn} do
      hook = "QuantumBillingWeb.DocumentFormComponents.HsnSuggest"

      {:ok, view, _html} = live(conn, ~p"/invoices/new")
      assert has_element?(view, ~s(#invoice-items[phx-hook="#{hook}"]))

      {:ok, view, _html} = live(conn, ~p"/quotations/new")
      assert has_element?(view, ~s(#quotation-items[phx-hook="#{hook}"]))
    end

    test "marks the fields the arrow keys and Enter work from", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      assert has_element?(view, ~s(input[name="invoice[items][0][description]"][data-hsn-input]))
      assert has_element?(view, ~s(input[name="invoice[items][0][hsn_sac]"][data-hsn-input]))
      refute has_element?(view, ~s(input[name="invoice[items][0][quantity]"][data-hsn-input]))

      type(view, %{"0" => line("Zxqv widget")}, 0, "description")
      view |> element("#invoice-hsn-find-0") |> render_click()

      assert has_element?(view, "#invoice-hsn-lookup-0[data-hsn-lookup]")
    end
  end

  describe "no match (criterion 5)" do
    test "leaves the field empty and offers Find HSN/SAC", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Zxqv widget")}, 0, "description")

      assert has_element?(view, panel(0), "No match. Nothing has been filled in.")
      assert has_element?(view, ~s(input[name="invoice[items][0][hsn_sac]"][value=""]))
      assert has_element?(view, "#invoice-hsn-find-0", "Find HSN/SAC")
    end

    test "Find HSN/SAC searches and returns the picked code to the row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")
      items = %{"0" => line("Zxqv widget")}

      type(view, items, 0, "description")
      view |> element("#invoice-hsn-find-0") |> render_click()
      assert has_element?(view, "#invoice-hsn-lookup-0")

      render_change(
        view,
        "validate",
        params(items) |> Map.put("hsn_lookup", "furniture") |> Map.put("_target", ["hsn_lookup"])
      )

      view |> element(option(0, "9401")) |> render_click()

      assert has_element?(view, ~s(input[name="invoice[items][0][hsn_sac]"][value="9401"]))
    end

    test "Escape (close) closes the suggestions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/new")

      type(view, %{"0" => line("Office chair")}, 0, "description")
      render_hook(view, "close_hsn", %{})

      refute has_element?(view, panel(0))
    end
  end

  test "the placeholder is neutral, not a real code (criterion 6)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    assert has_element?(
             view,
             ~s(input[name="invoice[items][0][hsn_sac]"][placeholder="e.g. 9401"])
           )

    refute render(view) =~ ~s(placeholder="998313")
  end

  test "off for a VAT business (criterion 7)", %{conn: conn} do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"},
        :tax
      )

    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    render_change(view, "validate", %{
      "invoice" => %{"client_name" => "Gulf Trading", "items" => %{"0" => line("Office chair")}},
      "_target" => ["invoice", "items", "0", "description"]
    })

    refute has_element?(view, panel(0))
    refute render(view) =~ "data-hsn-option"
  end

  test "works on quotations too (criterion 8)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/quotations/new")

    type(view, %{"0" => line("Office chair")}, 0, "description", "quotation")
    view |> element(option(0, "9401", "quotation")) |> render_click()

    assert has_element?(view, ~s(input[name="quotation[items][0][hsn_sac]"][value="9401"]))
  end
end
