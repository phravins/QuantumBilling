defmodule QuantumBilling.WorkerTest do
  @moduledoc """
  Jobs carry their business with them, and run in it.
  """
  use QuantumBilling.DataCase, async: true
  use Oban.Testing, repo: QuantumBilling.Repo

  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.Mail
  alias QuantumBilling.Workers.AuditPruneWorker
  alias QuantumBilling.Workers.EmailWorker

  # A row is enough for a sweep, which only queues jobs; nothing here runs in
  # these businesses, so they need no tables.
  defp business_row(id, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Business{id: id, name: "Firm #{id}", slug: "firm-#{id}", schema: "biz_#{id}"},
        attrs
      )
    )
  end

  defp job(worker, args), do: %Oban.Job{args: args, attempt: 1, max_attempts: 5, worker: worker}

  describe "new/2" do
    test "records the business that queued the job" do
      changeset = EmailWorker.new(%{"delivery_id" => 1})

      assert changeset.changes.args["business_id"] == 1
    end

    test "keeps a business given explicitly" do
      changeset = EmailWorker.new(%{"delivery_id" => 1, "business_id" => 7})

      assert changeset.changes.args["business_id"] == 7
    end

    test "records none when no business is chosen" do
      changeset = Repo.with_business(nil, fn -> EmailWorker.new(%{"delivery_id" => 1}) end)

      refute Map.has_key?(changeset.changes.args, "business_id")
    end
  end

  describe "perform/1" do
    test "a job from before there were several businesses runs in the first" do
      {:ok, delivery} = Mail.record_queued(%{to_email: "a@example.com"})

      # With no business it could not even look the delivery up.
      result =
        Repo.with_business(nil, fn ->
          {EmailWorker.perform(job("EmailWorker", %{"delivery_id" => delivery.id})),
           Repo.business()}
        end)

      assert {:discard, nil} = result
    end

    test "puts back the business that was current before" do
      business = Repo.business()

      EmailWorker.perform(job("EmailWorker", %{"delivery_id" => 0, "business_id" => 1}))

      assert Repo.business() == business
    end

    test "discards a job whose business no longer exists" do
      assert {:discard, "business 999999 no longer exists"} =
               EmailWorker.perform(
                 job("EmailWorker", %{"delivery_id" => 1, "business_id" => 999_999})
               )
    end
  end

  describe "a sweep" do
    test "queues one job per active business, and skips archived ones" do
      active = business_row(9_001)
      business_row(9_002, %{archived_at: DateTime.utc_now(:second)})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{businesses: 2}} =
                 AuditPruneWorker.perform(
                   job("AuditPruneWorker", %{"audit_retention_days" => 30})
                 )

        swept =
          [worker: AuditPruneWorker]
          |> all_enqueued()
          |> Enum.map(& &1.args)
          |> Enum.sort_by(& &1["business_id"])

        assert swept == [
                 %{"business_id" => 1, "audit_retention_days" => 30},
                 %{"business_id" => active.id, "audit_retention_days" => 30}
               ]
      end)
    end

    test "with a business, does the work there" do
      assert {:ok, %{audit_logs: _}} =
               AuditPruneWorker.perform(job("AuditPruneWorker", %{"business_id" => 1}))
    end
  end
end
