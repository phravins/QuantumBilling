defmodule QuantumBilling.Repo do
  @moduledoc """
  The repository, and which business it is working for.

  Each business keeps its records in a Postgres schema of its own (`biz_1`,
  `biz_2`, …), with its own copy of the business tables. The process that is
  serving a business — a request, a LiveView, a job — says so once with
  `put_business/1`, and every query and write it makes goes to that schema.
  Nothing else in the application names a schema.

  Accounts and the businesses themselves live in `public`, shared by all of
  them. Those schemas declare `@schema_prefix "public"`, which wins over the
  business for reads, and the write functions below leave them alone.

  With no business chosen, a query on a business table raises rather than
  guessing. The tables are no longer in `public`, so Postgres would refuse it
  anyway; the error here says why.
  """

  use Ecto.Repo,
    otp_app: :quantum_billing,
    adapter: Ecto.Adapters.Postgres

  @key {__MODULE__, :business}

  @doc """
  Makes `business` the one this process works for; `nil` clears it.

  A request process can be reused for the next request on the same connection,
  so whoever sets this for a request must clear it first.
  """
  def put_business(nil) do
    Process.delete(@key)
    nil
  end

  def put_business(%{schema: "biz_" <> _} = business) do
    Process.put(@key, business)
    business
  end

  @doc "The business this process works for, or `nil`."
  def business, do: Process.get(@key)

  @doc "The current business's Postgres schema. Raises when none is chosen."
  def business_schema! do
    case business() do
      %{schema: schema} -> schema
      nil -> raise QuantumBilling.Repo.NoBusinessError
    end
  end

  @doc """
  Runs `fun` for `business`, then puts back whatever was current before.

  For jobs and sweeps that work through several businesses in one process,
  and for anything that must not disturb the caller's own business.
  """
  def with_business(business, fun) when is_function(fun, 0) do
    previous = business()
    put_business(business)

    try do
      fun.()
    after
      put_business(previous)
    end
  end

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      Keyword.has_key?(opts, :prefix) or query.prefix != nil ->
        {query, opts}

      # Oban marks its own queries; the jobs table is shared, in `public`.
      Keyword.get(opts, :oban) ->
        {query, opts}

      # A migration's data queries go where the migration does: `public` for
      # the main ones (whose business tables were still there before the move),
      # the business's schema for the tenant ones. Ecto runs each migration in
      # a task of its own, so this never outlives it.
      migration = Process.get(:ecto_migration) ->
        {query, migration_prefix(opts, migration)}

      schema = current_schema() ->
        {query, Keyword.put(opts, :prefix, schema)}

      business_query?(query) ->
        raise QuantumBilling.Repo.NoBusinessError, query: query

      true ->
        {query, opts}
    end
  end

  defp current_schema do
    case business() do
      %{schema: schema} -> schema
      nil -> nil
    end
  end

  # Any source without a schema of its own would be read from the business.
  defp business_query?(%Ecto.Query{from: from, joins: joins}) do
    Enum.any?([from | joins], fn
      %{source: {_table, schema}} when is_atom(schema) and not is_nil(schema) ->
        schema.__schema__(:prefix) == nil

      %{source: {table, nil}} when is_binary(table) ->
        true

      _subquery_or_fragment ->
        false
    end)
  end

  # Writes. An explicit `:prefix` takes precedence over a schema's own prefix
  # for writes, so it is only added for a business record that is new to the
  # database: a loaded record already knows where it came from, and accounts
  # say `public` themselves.

  defoverridable insert: 1,
                 insert: 2,
                 insert!: 1,
                 insert!: 2,
                 update: 1,
                 update: 2,
                 update!: 1,
                 update!: 2,
                 delete: 1,
                 delete: 2,
                 delete!: 1,
                 delete!: 2,
                 insert_or_update: 1,
                 insert_or_update: 2,
                 insert_or_update!: 1,
                 insert_or_update!: 2,
                 insert_all: 2,
                 insert_all: 3

  @impl true
  def insert(struct_or_changeset, opts \\ []),
    do: super(struct_or_changeset, write_opts(struct_or_changeset, opts))

  @impl true
  def insert!(struct_or_changeset, opts \\ []),
    do: super(struct_or_changeset, write_opts(struct_or_changeset, opts))

  @impl true
  def update(changeset, opts \\ []), do: super(changeset, write_opts(changeset, opts))

  @impl true
  def update!(changeset, opts \\ []), do: super(changeset, write_opts(changeset, opts))

  @impl true
  def delete(struct_or_changeset, opts \\ []),
    do: super(struct_or_changeset, write_opts(struct_or_changeset, opts))

  @impl true
  def delete!(struct_or_changeset, opts \\ []),
    do: super(struct_or_changeset, write_opts(struct_or_changeset, opts))

  @impl true
  def insert_or_update(changeset, opts \\ []),
    do: super(changeset, write_opts(changeset, opts))

  @impl true
  def insert_or_update!(changeset, opts \\ []),
    do: super(changeset, write_opts(changeset, opts))

  @impl true
  def insert_all(source, entries, opts \\ []) do
    opts =
      cond do
        Keyword.has_key?(opts, :prefix) -> opts
        public_source?(source) -> opts
        true -> put_business_prefix(opts)
      end

    super(source, entries, opts)
  end

  defp write_opts(%Ecto.Changeset{data: data}, opts), do: write_opts(data, opts)

  defp write_opts(%{__meta__: %{prefix: nil}}, opts) do
    if Keyword.has_key?(opts, :prefix),
      do: opts,
      else: put_business_prefix(opts)
  end

  defp write_opts(_struct_with_prefix, opts), do: opts

  # Inside a migration, the migration's own prefix; see `prepare_query/3`.
  defp put_business_prefix(opts) do
    case Process.get(:ecto_migration) do
      nil -> Keyword.put(opts, :prefix, business_schema!())
      migration -> migration_prefix(opts, migration)
    end
  end

  defp migration_prefix(opts, %{prefix: nil}), do: opts
  defp migration_prefix(opts, %{prefix: prefix}), do: Keyword.put(opts, :prefix, prefix)

  defp public_source?({_table, schema}) when is_atom(schema), do: public_source?(schema)

  defp public_source?(schema) when is_atom(schema),
    do: schema.__schema__(:prefix) != nil

  defp public_source?(_table), do: false
end
