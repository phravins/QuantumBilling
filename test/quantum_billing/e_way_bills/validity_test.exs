defmodule QuantumBilling.EWayBills.ValidityTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.EWayBills.Validity

  describe "days/2" do
    # Rule 138(10): one day per 200 km "or part thereof".
    test "one day per 200 km, or part of one" do
      assert Validity.days(1) == 1
      assert Validity.days(200) == 1
      assert Validity.days(201) == 2
      assert Validity.days(400) == 2
      assert Validity.days(401) == 3
      assert Validity.days(1_800) == 9
    end

    test "over-dimensional cargo gets a day per 20 km" do
      assert Validity.days(20, :over_dimensional) == 1
      assert Validity.days(21, :over_dimensional) == 2
      assert Validity.days(200, :over_dimensional) == 10
    end

    # A half-filled consignment is still a bill, and a bill is good for a day.
    test "a missing distance is still a day" do
      assert Validity.days(nil) == 1
      assert Validity.days(0) == 1
    end
  end

  describe "valid_until/3" do
    test "expires at midnight, not at the hour it was generated" do
      assert Validity.valid_until(~N[2026-09-24 18:30:00], 150) == ~N[2026-09-25 23:59:59]
      assert Validity.valid_until(~N[2026-09-24 00:05:00], 150) == ~N[2026-09-25 23:59:59]
    end

    test "each further 200 km buys another whole day" do
      assert Validity.valid_until(~N[2026-09-24 09:00:00], 450) == ~N[2026-09-27 23:59:59]
    end

    test "takes a DateTime too" do
      assert Validity.valid_until(~U[2026-09-24 18:30:00Z], 150) == ~N[2026-09-25 23:59:59]
    end
  end
end
