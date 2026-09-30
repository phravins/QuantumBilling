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

  # How many clients a picker offers at once. Enough that a small business
  # never has to search, small enough that a large one does not ship its whole
  # customer list to the browser.
  @picker_limit 50

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

  @doc """
  Clients to offer in a picker: at most `@picker_limit` of them, matching
  `search`, with `selected_id` always included.

  The invoice form used to render `list_clients/0` into a `<select>`. On an
  account with fifty thousand customers that is fifty thousand `<option>`
  elements in the first page load and again in every LiveView diff that touches
  the form — megabytes over the socket for a list nobody can scroll through
  anyway.

  The selected client is fetched separately and prepended, because the invoice
  being edited must keep showing its own client even when the current search
  does not match it.
  """
  def picker_options(search \\ nil, selected_id \\ nil) do
    matches =
      Client
      |> search_where(search)
      |> order_by([c], asc: c.name, asc: c.id)
      |> limit(^@picker_limit)
      |> select([c], %{id: c.id, name: c.name})
      |> Repo.all()

    case selected_client(selected_id) do
      nil -> matches
      selected -> [selected | Enum.reject(matches, &(&1.id == selected.id))]
    end
  end

  @doc "How many options a picker offers before it asks to be searched."
  def picker_limit, do: @picker_limit

  defp selected_client(nil), do: nil
  defp selected_client(""), do: nil

  defp selected_client(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> selected_client(id)
      _not_an_id -> nil
    end
  end

  defp selected_client(id) when is_integer(id) do
    Client
    |> where([c], c.id == ^id)
    |> select([c], %{id: c.id, name: c.name})
    |> Repo.one()
  end

  defp selected_client(_other), do: nil

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
  Fetches a client by id, or `nil`.

  Takes the id as a string, because that is how it arrives from a form, and
  returns `nil` rather than raising for one that is not a number at all — a
  select can be sent anything.
  """
  def get_client(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> get_client(id)
      _not_an_id -> nil
    end
  end

  def get_client(id) when is_integer(id), do: Repo.get(Client, id)
  def get_client(_other), do: nil

  @doc """
  Fetches the client called exactly `name`, or `nil`.

  The comparison ignores case and surrounding spaces, because this is what
  answers "the user typed a client's name by hand instead of picking it" — but
  it is never a partial match: "Apex" must not become "Apex Retail Solutions"
  while the name is still being typed.

  Names are not unique. When several clients share one, the oldest wins, so the
  answer is at least the same every time.
  """
  def get_client_by_name(name) when is_binary(name) do
    case String.trim(name) do
      "" ->
        nil

      trimmed ->
        Client
        |> where([c], fragment("lower(btrim(?))", c.name) == ^String.downcase(trimmed))
        |> order_by([c], asc: c.id)
        |> limit(1)
        |> Repo.one()
    end
  end

  def get_client_by_name(_other), do: nil

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
