defmodule QuantumBillingWeb.HsnSuggestionsTest do
  @moduledoc """
  Issue #100, criterion 3: picking an HSN/SAC suggestion never replaces a
  code or GST rate the user did not get from a suggestion without asking.
  """
  use ExUnit.Case, async: true

  alias QuantumBillingWeb.HsnSuggestions

  @chair %{code: "9401", type: :hsn, rate: 18, description: "Seats", source: :catalogue}
  @drink %{code: "2202", type: :hsn, rate: 40, description: "Aerated drinks", source: :catalogue}

  setup do
    %{hsn: HsnSuggestions.init(%Phoenix.LiveView.Socket{}, false).assigns.hsn}
  end

  describe "confirm_pick?/5 does not ask" do
    test "on a new row", %{hsn: hsn} do
      refute HsnSuggestions.confirm_pick?(hsn, "0", "", "18", @chair)
      refute HsnSuggestions.confirm_pick?(hsn, "0", nil, 18, @chair)
    end

    test "when the row already has that code at the default rate", %{hsn: hsn} do
      refute HsnSuggestions.confirm_pick?(hsn, "0", " 9401 ", 18, @chair)
    end

    test "when the pick cannot change the rate and the row has no code", %{hsn: hsn} do
      # 40% is not on the form, so the row keeps its 5%.
      refute HsnSuggestions.confirm_pick?(hsn, "0", "", "5", @drink)
    end

    test "on a row filled from a suggestion", %{hsn: hsn} do
      hsn = %{hsn | suggested: MapSet.new(["0"])}

      refute HsnSuggestions.confirm_pick?(hsn, "0", "9403", "5", @chair)
    end
  end

  describe "confirm_pick?/5 asks" do
    test "when a saved or copied code would be replaced", %{hsn: hsn} do
      assert HsnSuggestions.confirm_pick?(hsn, "0", "998313", 18, @chair)
      assert HsnSuggestions.confirm_pick?(hsn, "0", "998313", "18", @drink)
    end

    test "when a saved rate would be replaced", %{hsn: hsn} do
      assert HsnSuggestions.confirm_pick?(hsn, "0", "", 5, @chair)
      assert HsnSuggestions.confirm_pick?(hsn, "0", nil, "0", @chair)
    end

    test "on a row typed by hand", %{hsn: hsn} do
      hsn = %{hsn | manual: MapSet.new(["1"])}

      assert HsnSuggestions.confirm_pick?(hsn, "1", "", "18", @chair)
      refute HsnSuggestions.confirm_pick?(hsn, "0", "", "18", @chair)
    end
  end

  test "confirm_message/1 names the code, and the rate only when it is applied" do
    assert HsnSuggestions.confirm_message(@chair) =~ "Replace them with HSN 9401 at 18%?"

    message = HsnSuggestions.confirm_message(@drink)
    assert message =~ "HSN 2202"
    assert message =~ "The GST rate stays as it is."
    refute message =~ "40%"
  end
end
