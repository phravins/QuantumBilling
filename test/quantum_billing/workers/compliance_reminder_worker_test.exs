defmodule QuantumBilling.Workers.ComplianceReminderWorkerTest do
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Notifications
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Workers.ComplianceReminderWorker

  # On this date April's GSTR-1 (due 11 May) and GSTR-3B (20 May) are overdue, and
  # May's GSTR-1 is fourteen days out, so the lead window decides it.
  @today ~D[2024-05-28]
  @gstin "27AABCU9603R1ZM"

  defp registration(over \\ %{}) do
    struct(%Organization{gstin: @gstin, reminder_lead_days: 7}, over)
  end

  defp titles do
    Notifications.recent(50) |> Enum.map(& &1.title)
  end

  describe "remind/2" do
    test "announces the obligations inside the lead window and nothing else" do
      assert ComplianceReminderWorker.remind(registration(), @today) == 2

      assert titles() == [
               "GSTR-3B for Apr 2024 is overdue",
               "GSTR-1 for Apr 2024 is overdue"
             ]
    end

    test "an overdue return is an error, not a warning" do
      ComplianceReminderWorker.remind(registration(), @today)

      assert Enum.all?(Notifications.recent(50), &(&1.severity == "error"))
    end

    test "each reminder carries the due date and a way to the page" do
      ComplianceReminderWorker.remind(registration(), @today)

      reminder = Enum.find(Notifications.recent(50), &(&1.title =~ "GSTR-3B"))

      assert reminder.kind == "compliance"
      assert reminder.body =~ "due 20 May 2024"
      assert reminder.path == "/compliance"
    end

    # The dedupe key is the reason this can run every morning. Without it the
    # feed would repeat an open deadline daily until it was filed.
    test "running again the next day writes nothing new" do
      assert ComplianceReminderWorker.remind(registration(), @today) == 2
      assert ComplianceReminderWorker.remind(registration(), Date.add(@today, 1)) == 0

      assert length(Notifications.recent(50)) == 2
    end

    test "a wider lead window reaches a deadline that has not passed yet" do
      assert ComplianceReminderWorker.remind(registration(%{reminder_lead_days: 14}), @today) == 3

      assert "GSTR-1 for May 2024 is due in 14 days" in titles()
    end

    test "a narrow window still catches what is already late" do
      assert ComplianceReminderWorker.remind(registration(%{reminder_lead_days: 0}), @today) == 2
    end

    test "names the day when the deadline is today" do
      ComplianceReminderWorker.remind(registration(), ~D[2024-05-20])

      assert "GSTR-3B for Apr 2024 is due today" in titles()
    end

    test "and tomorrow when it is tomorrow" do
      ComplianceReminderWorker.remind(registration(), ~D[2024-05-19])

      assert "GSTR-3B for Apr 2024 is due tomorrow" in titles()
    end

    test "a deadline not yet in sight is left alone" do
      # 19 May: April's GSTR-3B is due tomorrow and April's GSTR-1 is already
      # late, but May's GSTR-1 is twenty-three days off and stays quiet.
      assert ComplianceReminderWorker.remind(registration(), ~D[2024-05-19]) == 2

      refute Enum.any?(titles(), &(&1 =~ "May 2024"))
    end

    test "an unregistered business has no filing obligations to remind about" do
      assert ComplianceReminderWorker.remind(registration(%{gstin: nil}), @today) == 0
      assert Notifications.recent(50) == []
    end

    # A composition dealer files CMP-08, not GSTR-1 and GSTR-3B. The worker does
    # not decide this — `Compliance.tracked_obligations/2` does — but a reminder
    # for a return the business never files would be worse than no reminder.
    test "follows the scheme the organisation is actually on" do
      ComplianceReminderWorker.remind(registration(%{composition_scheme: true}), @today)

      refute Enum.any?(titles(), &(&1 =~ "GSTR-3B"))
    end
  end

  describe "perform/1" do
    test "writes the reminders for the stored organisation" do
      store(%{gstin: @gstin})

      assert {:ok, %{reminded: 2}} =
               perform_job(%{"today" => Date.to_iso8601(@today)})
    end

    test "does nothing at all when the business has turned reminders off" do
      store(%{gstin: @gstin, notify_filing_reminders: false})

      assert {:ok, :disabled} = perform_job(%{"today" => Date.to_iso8601(@today)})
      assert Notifications.recent(50) == []
    end

    test "falls back to today rather than failing on an unusable date" do
      store(%{gstin: @gstin})

      assert {:ok, %{reminded: _}} = perform_job(%{"today" => "not-a-date"})
      assert {:ok, %{reminded: _}} = perform_job(%{})
    end

    defp store(attrs) do
      Settings.ensure_organization()
      |> Ecto.Changeset.change(attrs)
      |> Repo.update!()
    end

    defp perform_job(args) do
      ComplianceReminderWorker.perform(%Oban.Job{args: args})
    end
  end
end
