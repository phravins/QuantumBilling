defmodule QuantumBillingWeb.SharedComponentsTest do
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.Component, only: [to_form: 1]
  import Phoenix.LiveViewTest
  import QuantumBillingWeb.SharedComponents

  alias QuantumBilling.EWayBills.EWayBillForm

  defp invalid_field(name) do
    %EWayBillForm{}
    |> EWayBillForm.validate(%{to_string(name) => ""})
    |> to_form()
    |> Access.get(name)
  end

  describe "a field in error" do
    # `input/1` already prints the errors; `field/1` must not repeat them.
    test "says so once, not twice" do
      html =
        render_component(&field/1, field: invalid_field(:distance_km), label: "Approx. Distance")

      assert count(html, "can&#39;t be blank") == 1
    end

    test "says so once on a select too" do
      html =
        render_component(&field/1,
          field: invalid_field(:transport_mode),
          label: "Transport Mode",
          type: "select",
          options: EWayBillForm.transport_modes()
        )

      assert count(html, "can&#39;t be blank") == 1
    end

    # The hint is the field's help text; it steps aside for the error rather
    # than stacking under it.
    test "hides its hint while the error is showing" do
      html =
        render_component(&field/1,
          field: invalid_field(:distance_km),
          label: "Approx. Distance",
          hint: "Road distance between the two pincodes"
        )

      assert html =~ "can&#39;t be blank"
      refute html =~ "Road distance between the two pincodes"
    end
  end

  describe "a field with nothing wrong" do
    test "shows its hint and no error" do
      field =
        %EWayBillForm{}
        |> EWayBillForm.validate(%{"distance_km" => "150"})
        |> to_form()
        |> Access.get(:distance_km)

      html = render_component(&field/1, field: field, label: "Approx. Distance", hint: "In km")

      assert html =~ "In km"
      refute html =~ "can&#39;t be blank"
    end
  end

  describe "pagination" do
    test "measures the screen only when asked to" do
      fitted = render_component(&pagination/1, current_page: 1, total_pages: 2, fit_rows: true)
      plain = render_component(&pagination/1, current_page: 1, total_pages: 2)

      assert fitted =~ ~s(id="pagination")
      assert fitted =~ "phx-hook"
      refute plain =~ "phx-hook"
    end
  end

  describe "fit_rows_per_page/1" do
    test "clamps to 5..100 and refuses what isn't a whole number" do
      assert fit_rows_per_page(15) == {:ok, 15}
      assert fit_rows_per_page("15") == {:ok, 15}
      assert fit_rows_per_page(0) == {:ok, 5}
      assert fit_rows_per_page("9000") == {:ok, 100}
      assert fit_rows_per_page("15px") == :error
      assert fit_rows_per_page(nil) == :error
    end
  end

  defp count(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
