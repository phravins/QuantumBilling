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
    # `field/1` wraps `input/1`, which prints the errors itself. `field/1`
    # printed them a second time underneath, so every blank required field on
    # every form in the application said "can't be blank" twice.
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

  defp count(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
