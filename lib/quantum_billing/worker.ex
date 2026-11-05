defmodule QuantumBilling.Worker do
  @moduledoc """
  An Oban worker that runs in the business that queued it.

  `use QuantumBilling.Worker` (same options as `Oban.Worker`) and implement
  `process/1`. `new/2` stores `"business_id"` in the args; `perform/1` makes it
  current, then restores the previous one. Jobs without it run in the first
  business.

  With `sweep: true` (or `sweep?/1`), a job with no business queues one copy
  per active business instead, so each is retried on its own.
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
