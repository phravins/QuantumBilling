defmodule QuantumBilling.Worker do
  @moduledoc """
  An Oban worker that runs inside the business that queued it.

  A job runs in an Oban process, which has no business of its own, so the
  business has to travel with the job. `use QuantumBilling.Worker` in place of
  `use Oban.Worker` (it takes the same options) and write `process/1` instead
  of `perform/1`:

    * `new/2` records the current business as `"business_id"` in the args;
    * `perform/1` makes that business current, calls `process/1`, then puts back
      whatever was current before — inline jobs in tests run in the test's own
      process, and must not leave it pointing somewhere else.

  A job queued before there were several businesses carries no `"business_id"`
  and runs in the first business, where its records are.

  ## Sweeps

  The cron jobs are queued by Oban with no business at all. A worker that is
  one passes `sweep: true`: without a `"business_id"` it queues a copy of itself
  for every active business and stops there, so each business is swept by a
  job of its own and one that fails is retried without repeating the others.
  Archived businesses are not swept. A worker that is a sweep only for some
  args overrides `sweep?/1` instead.
  """

  alias QuantumBilling.Businesses
  alias QuantumBilling.Repo

  @doc "Does the work, with the job's business already current."
  @callback process(Oban.Job.t()) :: Oban.Worker.result()

  @doc "Whether a job with these args and no business sweeps every business."
  @callback sweep?(args :: map()) :: boolean()

  defmacro __using__(opts) do
    {sweep?, oban_opts} = Keyword.pop(opts, :sweep, false)

    quote location: :keep do
      use Oban.Worker, unquote(oban_opts)

      @behaviour QuantumBilling.Worker

      # Oban's own `new/1` calls this one.
      @impl Oban.Worker
      def new(args, opts) when is_map(args) and is_list(opts) do
        super(QuantumBilling.Worker.with_business_id(args), opts)
      end

      @impl QuantumBilling.Worker
      def sweep?(_args), do: unquote(sweep?)

      @impl Oban.Worker
      def perform(%Oban.Job{} = job), do: QuantumBilling.Worker.perform(__MODULE__, job)

      defoverridable sweep?: 1
    end
  end

  @doc false
  def with_business_id(args) do
    case Repo.business() do
      %{id: id} -> Map.put_new(args, "business_id", id)
      nil -> args
    end
  end

  @doc false
  def perform(worker, %Oban.Job{} = job) do
    args = job.args || %{}

    case Map.get(args, "business_id") do
      nil ->
        if worker.sweep?(args),
          do: sweep(worker, args),
          else: Repo.with_business(Businesses.default!(), fn -> worker.process(job) end)

      id ->
        case Businesses.get(id) do
          nil -> {:discard, "business #{id} no longer exists"}
          business -> Repo.with_business(business, fn -> worker.process(job) end)
        end
    end
  end

  defp sweep(worker, args) do
    jobs =
      for business <- Businesses.list_active() do
        args
        |> Map.put("business_id", business.id)
        |> worker.new()
      end

    _ = Oban.insert_all(jobs)
    {:ok, %{businesses: length(jobs)}}
  end
end
