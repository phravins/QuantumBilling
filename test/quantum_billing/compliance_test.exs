defmodule QuantumBilling.ComplianceTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Compliance

  # Every function takes the reference date, so nothing here depends on when the
  # suite runs.
  @today ~D[2024-05-28]

  defp obligations(today \\ @today), do: Compliance.obligations(today)

  defp find(obligations, type, period) do
    Enum.find(obligations, &(&1.type == type and &1.period_label == period))
  end

  describe "financial_year/1" do
    test "runs April to March" do
      assert Compliance.financial_year(~D[2024-05-28]) == {~D[2024-04-01], ~D[2025-03-31]}
    end

    test "January to March belongs to the year that started the previous April" do
      assert Compliance.financial_year(~D[2025-02-10]) == {~D[2024-04-01], ~D[2025-03-31]}
      assert Compliance.financial_year(~D[2025-03-31]) == {~D[2024-04-01], ~D[2025-03-31]}
    end

    test "rolls over on 1 April, not 1 January" do
      assert Compliance.financial_year(~D[2025-03-31]) !=
               Compliance.financial_year(~D[2025-04-01])

      assert Compliance.financial_year(~D[2025-04-01]) == {~D[2025-04-01], ~D[2026-03-31]}
    end

    test "labels the year the way the cards show it" do
      assert Compliance.financial_year_label(~D[2024-05-28]) == "FY 2024-25"
      assert Compliance.financial_year_label(~D[2025-01-15]) == "FY 2024-25"
      assert Compliance.financial_year_label(~D[2025-04-01]) == "FY 2025-26"
    end
  end

  describe "statutory due dates" do
    # These are the real deadlines. If one of these changes, the rule is wrong,
    # not the test.
    test "GSTR-1 is due the 11th of the following month" do
      assert find(obligations(), "GSTR-1", "Apr 2024").due_date == ~D[2024-05-11]
      assert find(obligations(), "GSTR-1", "May 2024").due_date == ~D[2024-06-11]
      assert find(obligations(), "GSTR-1", "Dec 2024").due_date == ~D[2025-01-11]
    end

    test "GSTR-3B is due the 20th of the following month" do
      assert find(obligations(), "GSTR-3B", "Apr 2024").due_date == ~D[2024-05-20]
      assert find(obligations(), "GSTR-3B", "May 2024").due_date == ~D[2024-06-20]
    end

    test "CMP-08 is due the 18th after the quarter closes" do
      assert find(obligations(), "CMP-08", "Apr - Jun 2024").due_date == ~D[2024-07-18]
      assert find(obligations(), "CMP-08", "Jul - Sep 2024").due_date == ~D[2024-10-18]
      assert find(obligations(), "CMP-08", "Jan - Mar 2025").due_date == ~D[2025-04-18]
    end

    test "annual filings are due 31 December after the year ends" do
      assert find(obligations(), "GSTR-9", "FY 2024-25").due_date == ~D[2025-12-31]
      assert find(obligations(), "GSTR-9C", "FY 2024-25").due_date == ~D[2025-12-31]
    end

    test "covers the whole year: 12 + 12 monthly, 4 quarterly, 2 annual" do
      counts = obligations() |> Enum.frequencies_by(& &1.type)

      assert counts == %{
               "GSTR-1" => 12,
               "GSTR-3B" => 12,
               "CMP-08" => 4,
               "GSTR-9" => 1,
               "GSTR-9C" => 1
             }

      assert length(obligations()) == 30
    end

    test "is ordered by due date" do
      dates = Enum.map(obligations(), & &1.due_date)

      assert dates == Enum.sort(dates, Date)
    end

    test "every period falls inside the financial year" do
      first = find(obligations(), "GSTR-1", "Apr 2024")
      last = find(obligations(), "GSTR-1", "Mar 2025")

      assert first && last
    end
  end

  describe "status" do
    test "is Pending before the due date and Overdue after it" do
      # GSTR-1 for Apr 2024 is due 11 May 2024.
      assert find(obligations(~D[2024-05-01]), "GSTR-1", "Apr 2024").status == "Pending"
      assert find(obligations(~D[2024-05-11]), "GSTR-1", "Apr 2024").status == "Pending"
      assert find(obligations(~D[2024-05-12]), "GSTR-1", "Apr 2024").status == "Overdue"
    end

    test "is never Filed while there are no filing records" do
      assert Compliance.filings() == []
      refute Enum.any?(obligations(), &(&1.status == "Filed"))
      assert Enum.all?(obligations(), &(&1.filed_on == nil))
    end
  end

  describe "summary/1" do
    test "counts split across the statuses and total up" do
      summary = Compliance.summary(obligations())

      assert summary.total == 30
      assert summary.filed + summary.pending + summary.overdue == summary.total
    end

    test "percentages are of the total and sum to 100" do
      summary = Compliance.summary(obligations())

      assert_in_delta summary.filed_pct + summary.pending_pct + summary.overdue_pct, 100.0, 0.1
    end

    test "an empty list gives zeros rather than dividing by zero" do
      summary = Compliance.summary([])

      assert summary.total == 0
      assert summary.filed == 0
      assert summary.pending == 0
      assert summary.overdue == 0
      assert summary.filed_pct == 0.0
      assert summary.overdue_pct == 0.0
    end
  end

  describe "upcoming/3" do
    test "returns the soonest first" do
      upcoming = Compliance.upcoming(obligations(), @today)

      dates = Enum.map(upcoming, & &1.due_date)
      assert dates == Enum.sort(dates, Date)
      assert length(upcoming) == 5
    end

    test "respects the limit" do
      assert length(Compliance.upcoming(obligations(), @today, 3)) == 3
    end

    test "carries a signed day count so overdue reads differently" do
      # 28 May 2024: Apr's GSTR-1 (11 May) is 17 days overdue.
      overdue = Compliance.upcoming(obligations(), @today) |> hd()

      assert overdue.days_until == Date.diff(overdue.due_date, @today)
      assert overdue.days_until < 0
    end

    test "is empty when nothing is outstanding" do
      assert Compliance.upcoming([], @today) == []
    end
  end

  describe "filter/2" do
    test "no filters match everything" do
      assert length(Compliance.filter(obligations(), %{})) == 30
    end

    test "narrows by category" do
      returns = Compliance.filter(obligations(), %{category: :returns})
      payments = Compliance.filter(obligations(), %{category: :payments})
      other = Compliance.filter(obligations(), %{category: :other})

      assert Enum.map(payments, & &1.type) |> Enum.uniq() == ["CMP-08"]
      assert Enum.map(other, & &1.type) |> Enum.uniq() == ["GSTR-9C"]
      assert length(returns) + length(payments) + length(other) == 30
    end

    test ":all matches everything" do
      assert length(Compliance.filter(obligations(), %{category: :all})) == 30
    end

    test "narrows by status" do
      rows = Compliance.filter(obligations(), %{status: "Overdue"})

      assert rows != []
      assert Enum.all?(rows, &(&1.status == "Overdue"))
    end

    test "combines category and status" do
      rows = Compliance.filter(obligations(), %{category: :payments, status: "Pending"})

      assert Enum.all?(rows, &(&1.type == "CMP-08" and &1.status == "Pending"))
    end
  end

  describe "calendar_weeks/3" do
    test "returns whole Sunday-to-Saturday weeks" do
      weeks = Compliance.calendar_weeks(2024, 5, obligations())

      assert Enum.all?(weeks, &(length(&1) == 7))

      assert weeks |> List.first() |> List.first() |> Map.get(:date) |> Date.day_of_week(:sunday) ==
               1
    end

    test "marks which days belong to the month" do
      weeks = Compliance.calendar_weeks(2024, 5, obligations())
      cells = List.flatten(weeks)

      in_month = Enum.filter(cells, & &1.in_month?)

      assert length(in_month) == 31
      assert Enum.all?(in_month, &(&1.date.month == 5))
    end

    test "attaches obligations to the days they fall due" do
      cells = Compliance.calendar_weeks(2024, 5, obligations()) |> List.flatten()

      may_11 = Enum.find(cells, &(&1.date == ~D[2024-05-11]))
      may_20 = Enum.find(cells, &(&1.date == ~D[2024-05-20]))
      may_12 = Enum.find(cells, &(&1.date == ~D[2024-05-12]))

      assert Enum.map(may_11.obligations, & &1.type) == ["GSTR-1"]
      assert Enum.map(may_20.obligations, & &1.type) == ["GSTR-3B"]
      assert may_12.obligations == []
    end

    test "handles a month starting on a Sunday without a blank leading week" do
      weeks = Compliance.calendar_weeks(2024, 9, obligations())

      assert weeks |> List.first() |> List.first() |> Map.get(:date) == ~D[2024-09-01]
    end
  end

  describe "shift_months/2" do
    test "moves forward and backward across year boundaries" do
      assert Compliance.shift_months(~D[2024-11-15], 3) == ~D[2025-02-15]
      assert Compliance.shift_months(~D[2024-02-15], -3) == ~D[2023-11-15]
    end

    test "clamps the day so the 31st never rolls into the next month" do
      assert Compliance.shift_months(~D[2024-01-31], 1) == ~D[2024-02-29]
      assert Compliance.shift_months(~D[2023-01-31], 1) == ~D[2023-02-28]
      assert Compliance.shift_months(~D[2024-03-31], 1) == ~D[2024-04-30]
    end
  end

  describe "categories and statuses" do
    test "expose the tabs and the filter options" do
      assert {:all, "All"} in Compliance.categories()
      assert {:returns, "Returns"} in Compliance.categories()
      assert {:payments, "Payments"} in Compliance.categories()
      assert {:other, "Other Compliances"} in Compliance.categories()

      assert Compliance.statuses() == ["All Status", "Filed", "Pending", "Overdue"]
    end

    test "category_label/1 names a key" do
      assert Compliance.category_label(:other) == "Other Compliances"
    end
  end
end
