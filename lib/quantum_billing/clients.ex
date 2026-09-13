defmodule QuantumBilling.Clients do
  @moduledoc """
  Customers a tenant invoices.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Events
  alias QuantumBilling.Repo

  @doc """
  Subscribes the caller to client changes.

  See `QuantumBilling.Events` for the messages and why the topic is
  organisation-wide rather than per user.
  """
  def subscribe, do: Events.subscribe(Events.clients_topic())

  # The list page's sortable columns. An allowlist, because the field arrives
  # from a click in the browser and ends up in an ORDER BY.
  @sortable %{name: :name, outstanding: :outstanding, status: :status}

  @default_per_page 10
  @max_per_page 200

  @doc """
  Every client, alphabetically.

  Unbounded — for exports, backups and tests. Screens use `page/1`.
  """
  def list_clients do
    Repo.all(from c in Client, order_by: [asc: c.name])
  end

  @doc """
  One page of clients, searched, filtered, sorted and counted by the database.

  Returns `%{rows:, total:, page:, per_page:, total_pages:}`. Same reasoning as
  `QuantumBilling.Invoices.page/1`: a customer directory is the other table
  that only ever grows, and it was being copied into every open browser tab.

  ## Options

    * `:search` — matches name, GSTIN or email
    * `:status` — exact status, or `"All Status"`
    * `:sort_field` / `:sort_dir`
    * `:page` / `:per_page`
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)

    query =
      Client
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status))

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(ceil(total / per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> clamp(1, total_pages)

    rows =
      query
      |> order(Keyword.get(opts, :sort_field), Keyword.get(opts, :sort_dir, :asc))
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{rows: rows, total: total, page: page, per_page: per_page, total_pages: total_pages}
  end

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

  defp search_where(query, blank) when blank in [nil, ""], do: query

  defp search_where(query, search) do
    pattern = "%" <> String.trim(search) <> "%"

    where(
      query,
      [c],
      ilike(c.name, ^pattern) or ilike(c.gstin, ^pattern) or ilike(c.email, ^pattern)
    )
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query
  defp status_where(query, status), do: where(query, [c], c.status == ^status)

  # No column chosen: alphabetical, which is what the directory has always
  # shown by default.
  defp order(query, nil, _direction), do: order_by(query, [c], asc: c.name, asc: c.id)

  defp order(query, field, direction) do
    case Map.fetch(@sortable, field) do
      {:ok, column} ->
        direction = if direction == :desc, do: :desc, else: :asc
        order_by(query, [c], [{^direction, field(c, ^column)}, {^direction, c.id}])

      :error ->
        order(query, nil, direction)
    end
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  @doc """
  Fetches a client by id, raising when it does not exist.
  """
  def get_client!(id), do: Repo.get!(Client, id)

  @doc """
  Builds a changeset for a client form.
  """
  def change_client(%Client{} = client \\ %Client{}, attrs \\ %{}) do
    Client.changeset(client, attrs)
  end

  @doc """
  Creates a client.
  """
  def create_client(attrs) do
    %Client{}
    |> Client.changeset(attrs)
    |> Repo.insert()
    |> announce(:client_created)
  end

  @doc """
  Updates a client.
  """
  def update_client(%Client{} = client, attrs) do
    client
    |> Client.changeset(attrs)
    |> Repo.update()
    |> announce(:client_updated)
  end

  # Only a successful write is announced, and the notification never changes
  # the result the caller gets back.
  defp announce({:ok, client} = result, event) do
    Events.broadcast(Events.clients_topic(), {event, client})
    result
  end

  defp announce({:error, _changeset} = result, _event), do: result

  @doc """
  Whether a client of this type must supply a GSTIN.

  The form asks this to decide whether to show the required marker, so the
  asterisk and the changeset can never disagree.
  """
  defdelegate gstin_required?(client_type), to: Client

  defdelegate client_types(), to: Client
  defdelegate business_types(), to: Client
  defdelegate categories(), to: Client
  defdelegate country_codes(), to: Client
  defdelegate statuses(), to: Client
end
