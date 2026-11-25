defmodule QuantumBilling.ComplianceFilingsTest do
  @moduledoc """
  Marking a GST return filed, and undoing it, against the database.

  `mark_filed/4` only takes obligations from this financial year or the last,
  counted from the real today, so these tests pick last year's April returns:
  always in that window and always past due. Statuses are read on the last day
  of that year, which has always gone by.
  """
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Compliance
  alias QuantumBilling.Compliance.Filing

  setup do
    scope = %{Scope.for_user(user_fixture()) | business: Repo.business()}

    {_from, last_year_end} =
      Compliance.financial_year(Compliance.shift_months(Date.utc_today(), -12))

    april_gstr1 =
      last_year_end
      |> Compliance.obligations(%{})
      |> Enum.filter(&(&1.type == "GSTR-1"))
      |> Enum.min_by(& &1.due_date, Date)

    %{scope: scope, on: last_year_end, return: april_gstr1}
  end

  defp status(on, %{type: type, period_key: period_key}) do
    on
    |> Compliance.obligations()
    |> Enum.find(&(&1.type == type and &1.period_key == period_key))
  end

  defp audited?(action, filing_id) do
    Repo.exists?(
      from l in AuditLog,
        where: l.action == ^action and l.resource_id == ^to_string(filing_id)
    )
  end

  describe "mark_filed/4" do
    test "makes the return Filed with its date and ARN, and audits it", ctx do
      %{scope: scope, on: on, return: return} = ctx
      assert status(on, return).status == "Overdue"

      assert {:ok, filing} =
               Compliance.mark_filed(scope, return.type, return.period_key, %{
                 "filed_on" => return.due_date,
                 "arn" => "aa 2704 2412 34567",
                 "note" => "  Filed by the accountant  "
               })

      assert filing.user_id == scope.user.id
      assert filing.arn == "AA2704241234567"
      assert filing.note == "Filed by the accountant"

      filed = status(on, return)
      assert filed.status == "Filed"
      assert filed.filed_on == return.due_date
      assert filed.filing.arn == "AA2704241234567"

      assert audited?("mark_compliance_filed", filing.id)
    end

    test "refuses a return the calendar does not generate", %{scope: scope, return: return} do
      assert {:error, :unknown_obligation} =
               Compliance.mark_filed(scope, "GSTR-99", return.period_key, %{
                 "filed_on" => return.due_date
               })

      assert {:error, :unknown_obligation} =
               Compliance.mark_filed(scope, return.type, "132026", %{
                 "filed_on" => return.due_date
               })

      assert {:error, :unknown_obligation} =
               Compliance.mark_filed(scope, return.type, "042019", %{"filed_on" => ~D[2019-05-10]})

      assert {:error, :unknown_obligation} =
               Compliance.mark_filed(scope, nil, nil, %{"filed_on" => return.due_date})

      assert Repo.aggregate(Filing, :count) == 0
    end

    test "refuses a date after today", %{scope: scope, return: return} do
      tomorrow = Date.add(Date.utc_today(), 2)

      assert {:error, changeset} =
               Compliance.mark_filed(scope, return.type, return.period_key, %{
                 "filed_on" => tomorrow
               })

      assert %{filed_on: ["can't be in the future"]} = errors_on(changeset)
    end

    test "needs a date, and an ARN in the portal's shape", %{scope: scope, return: return} do
      assert {:error, changeset} =
               Compliance.mark_filed(scope, return.type, return.period_key, %{
                 "filed_on" => "",
                 "arn" => "ARN-123"
               })

      assert %{filed_on: [_], arn: ["should be the 15-character ARN from the GST portal"]} =
               errors_on(changeset)
    end

    test "a return can be marked only once", %{scope: scope, return: return} do
      attrs = %{"filed_on" => return.due_date}

      assert {:ok, _filing} = Compliance.mark_filed(scope, return.type, return.period_key, attrs)

      assert {:error, changeset} =
               Compliance.mark_filed(scope, return.type, return.period_key, attrs)

      assert %{filed_on: ["this return is already marked as filed"]} = errors_on(changeset)
    end

    test "type and period come from the arguments, never the form", %{
      scope: scope,
      return: return
    } do
      assert {:ok, filing} =
               Compliance.mark_filed(scope, return.type, return.period_key, %{
                 "filed_on" => return.due_date,
                 "type" => "GSTR-9",
                 "period_key" => "032099",
                 "user_id" => -1
               })

      assert {filing.type, filing.period_key, filing.user_id} ==
               {return.type, return.period_key, scope.user.id}
    end
  end

  describe "undo_filed/3" do
    test "puts the return back to Overdue and audits it", %{scope: scope, on: on, return: return} do
      {:ok, filing} =
        Compliance.mark_filed(scope, return.type, return.period_key, %{
          "filed_on" => return.due_date
        })

      assert {:ok, _filing} = Compliance.undo_filed(scope, return.type, return.period_key)

      assert status(on, return).status == "Overdue"
      assert Repo.aggregate(Filing, :count) == 0
      assert audited?("undo_compliance_filed", filing.id)
    end

    test "a return that is not filed has nothing to undo", %{scope: scope, return: return} do
      assert {:error, :not_found} = Compliance.undo_filed(scope, return.type, return.period_key)
      assert {:error, :not_found} = Compliance.undo_filed(scope, "GSTR-99", "042019")
    end
  end
end
