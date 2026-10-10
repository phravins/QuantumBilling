defmodule QuantumBilling.Clients do
  @moduledoc """
  Customers a tenant invoices.

  ## Deleting

  `delete_client/2` moves a client to the Bin: it leaves the directory, the
  pickers and every lookup here, and its invoices stay exactly as they were —
  they carry their own copy of the client's name and GSTIN. `restore_client/2`
  brings it back and `purge_client/2` removes it for good.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.Events
  alias QuantumBilling.Repo

  @doc """
  Subscribes the caller to client changes.

  See `QuantumBilling.Events` for the messages and why the topic is
  organisation-wide rather than per user.
  """
  def subscribe, do: Events.subscribe(Events.clients_topic())

  # Allowlisted: the sort field comes from the browser.
  @sortable %{name: :name, outstanding: :outstanding, status: :status}

  @default_per_page 10
  @max_per_page 200

  @picker_limit 50

  @doc """
  Every client, alphabetically.

  Unbounded — for exports, backups and tests. Screens use `page/1`.
  """
  def list_clients do
    Repo.all(from c in Client.kept(), order_by: [asc: c.name])
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
      Client.kept()
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
  does not match it. That holds for a client that has since been moved to the
  Bin too — the matches leave it out, the selected one does not.
  """
  def picker_options(search \\ nil, selected_id \\ nil) do
    matches =
      Client.kept()
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
  Fetches a client by id, raising when it does not exist or is in the Bin.
  """
  def get_client!(id), do: Repo.get!(Client.kept(), id)

  @doc """
  Fetches a client by id, or `nil` — including for one that is in the Bin.

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

  def get_client(id) when is_integer(id), do: Repo.get(Client.kept(), id)
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
        Client.kept()
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

  defp announce({:ok, client} = result, event) do
    Events.broadcast(Events.clients_topic(), {event, client})
    result
  end

  defp announce({:error, _changeset} = result, _event), do: result

  @doc """
  Moves a client to the Bin.

  Nothing that belongs to the client is touched: its invoices, credit notes and
  recurring profiles all stay, still pointing at it. What changes is that it
  can no longer be picked for a new invoice, and its recurring profiles stop
  billing until it is restored — see `QuantumBilling.Recurring.due_profiles/1`.

  `opts` may carry `:user_id`, recorded against the audit entry.
  """
  def delete_client(client, opts \\ [])

  def delete_client(%Client{deleted_at: %DateTime{}} = client, _opts), do: {:ok, client}

  def delete_client(%Client{} = client, opts) do
    client
    |> Client.bin_changeset()
    |> Repo.update()
    |> audited(:bin_client, opts)
    |> announce(:client_binned)
  end

  @doc """
  Takes a client back out of the Bin.

  Returns `{:error, :gstin_taken}` when another client has been registered
  under its GSTIN while it was away. Two live clients cannot share one, and
  which of them is the real one is not something to guess at.
  """
  def restore_client(%Client{} = client, opts \\ []) do
    client
    |> Client.restore_changeset()
    |> Repo.update()
    |> case do
      {:error, %Ecto.Changeset{}} -> {:error, :gstin_taken}
      result -> result
    end
    |> audited(:restore_client, opts)
    |> announce(:client_restored)
  end

  @doc """
  Deletes a client for good.

  Returns `{:error, :not_in_bin}` for a client that has not been binned first,
  and `{:error, :in_use}` while it has credit notes: a note is a tax document
  raised against a client and cannot be left pointing at nobody.

  Invoices and recurring profiles do not hold it back. They keep their own copy
  of the client's details and simply stop being linked to a client record.
  """
  def purge_client(client, opts \\ [])

  def purge_client(%Client{deleted_at: nil}, _opts), do: {:error, :not_in_bin}

  def purge_client(%Client{} = client, opts) do
    if in_use?(client) do
      {:error, :in_use}
    else
      client
      |> Repo.delete()
      |> audited(:purge_client, opts)
      |> announce(:client_purged)
    end
  end

  @doc "Whether anything stops this client being deleted for good."
  def in_use?(%Client{id: nil}), do: false

  def in_use?(%Client{id: id}) do
    Repo.exists?(from n in CreditNote, where: n.client_id == ^id)
  end

  @doc "Every client in the Bin, most recently deleted first."
  def list_deleted_clients do
    Repo.all(from c in Client.binned(), order_by: [desc: c.deleted_at, desc: c.id])
  end

  @doc "One client in the Bin by id, or `nil` — including for an id that is not a number."
  def get_deleted_client(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> Repo.get(Client.binned(), int_id)
      _not_an_id -> nil
    end
  end

  defp audited({:ok, %Client{} = client} = result, action, opts) do
    Audit.log_event(action, "Client", client.id,
      user_id: Keyword.get(opts, :user_id),
      details: %{name: client.name, gstin: client.gstin}
    )

    result
  end

  defp audited(result, _action, _opts), do: result

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
