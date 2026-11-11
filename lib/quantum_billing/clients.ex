defmodule QuantumBilling.Clients do
  @moduledoc """
  Customers a business invoices. Deleting moves a client to the Bin; invoices keep their own copy.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Clients.Import
  alias QuantumBilling.CreditNotes.CreditNote
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices
  alias QuantumBilling.Paging
  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks

  @doc "Subscribes the caller to client changes."
  def subscribe, do: Events.subscribe(Events.clients_topic())

  # Allowlisted: the sort field comes from the browser.
  @sortable %{name: :name, outstanding: :outstanding, status: :status}

  @default_per_page 10
  @max_per_page 200

  @picker_limit 50

  @doc "Every client, alphabetically. Unbounded; screens use `page/1`."
  def list_clients do
    Repo.all(from c in Client.kept(), order_by: [asc: c.name])
  end

  @doc """
  One page of clients, filtered and sorted in the database.

  Options: `:search`, `:status`, `:sort_field`, `:sort_dir`, `:page`, `:per_page`,
  and `:custom`, a map of custom-field filters (see `CustomFields.filter_where/3`).
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)

    sort_field = Keyword.get(opts, :sort_field)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)

    query =
      Client.kept()
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status))
      |> custom_where(Keyword.get(opts, :custom))

    # `:keyset` pages newest-created first below `:before_id`, for the API.
    result =
      if Keyword.get(opts, :keyset, false) do
        Paging.keyset(query, Keyword.get(opts, :before_id), per_page)
      else
        Paging.page(query, &order(&1, sort_field, sort_dir),
          page: Keyword.get(opts, :page, 1),
          per_page: per_page
        )
      end

    %{result | rows: put_outstanding(result.rows)}
  end

  @doc """
  Every client matching the list filters, alphabetically, with what each owes,
  for CSV export. Takes `page/1`'s `:search`, `:status` and `:custom`.
  """
  def export_rows(opts \\ []) do
    Client.kept()
    |> search_where(Keyword.get(opts, :search))
    |> status_where(Keyword.get(opts, :status))
    |> custom_where(Keyword.get(opts, :custom))
    |> order(nil, :asc)
    |> Repo.all()
    |> put_outstanding()
  end

  @doc "What `client` still owes in paise, computed from its invoices and notes."
  def outstanding(%Client{id: id}) do
    case Repo.one(Invoices.outstanding_by_client([id])) do
      %{outstanding: owed} -> owed
      nil -> 0
    end
  end

  defp put_outstanding([]), do: []

  defp put_outstanding(clients) do
    owed =
      clients
      |> Enum.map(& &1.id)
      |> Invoices.outstanding_by_client()
      |> Repo.all()
      |> Map.new(&{&1.client_id, &1.outstanding})

    Enum.map(clients, &%{&1 | outstanding: Map.get(owed, &1.id, 0)})
  end

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

  @doc "Clients for a picker: up to `@picker_limit` matching `search`, plus `selected_id`."
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
      ilike(c.name, ^pattern) or ilike(c.gstin, ^pattern) or ilike(c.email, ^pattern) or
        ilike(c.tax_number, ^pattern)
    )
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query
  defp status_where(query, status), do: where(query, [c], c.status == ^status)

  defp custom_where(query, filters) when filters in [nil, %{}], do: query

  defp custom_where(query, filters),
    do: CustomFields.filter_where(query, CustomFields.active_definitions("client"), filters)

  defp order(query, nil, _direction), do: order_by(query, [c], asc: c.name, asc: c.id)

  # Outstanding is computed, so sorting by it groups every invoice.
  defp order(query, :outstanding, direction) do
    direction = if direction == :desc, do: :desc, else: :asc

    query
    |> join(:left, [c], o in subquery(Invoices.outstanding_by_client()), on: o.client_id == c.id)
    |> order_by([c, o], [{^direction, coalesce(o.outstanding, 0)}, {^direction, c.id}])
  end

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

  @doc "Fetches a non-binned client. Raises if missing."
  def get_client!(id), do: Repo.get!(Client.kept(), id)

  @doc "Fetches a non-binned client by string id, or `nil` (also for bad ids)."
  def get_client(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> get_client(id)
      _not_an_id -> nil
    end
  end

  def get_client(id) when is_integer(id), do: Repo.get(Client.kept(), id)
  def get_client(_other), do: nil

  @doc "The client named exactly `name` (case and spaces ignored), oldest first, or `nil`."
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
  def change_client(%Client{} = client \\ %Client{}, attrs \\ %{}, regime \\ nil) do
    Client.changeset(client, attrs, regime || tax_regime())
  end

  @doc """
  Creates a client.
  """
  def create_client(attrs) do
    %Client{}
    |> Client.changeset(attrs, tax_regime())
    |> Repo.insert()
    |> announce(:client_created)
  end

  @doc """
  Updates a client.
  """
  def update_client(%Client{} = client, attrs) do
    client
    |> Client.changeset(attrs, tax_regime())
    |> Repo.update()
    |> announce(:client_updated)
  end

  @doc """
  Creates many clients from import rows (attrs from `Clients.Import`), all or
  none, in one transaction.

  One `{:clients_imported, count}` goes to subscribers instead of a message
  per client; webhooks still get `client.created` for each. `opts` may carry
  `:user_id` and `:file` for the audit entry.

  Returns `{:ok, clients}` or `{:error, changeset}` for the first row that
  failed (for instance, a GSTIN another person saved meanwhile).
  """
  def import_clients(attrs_list, opts \\ []) when is_list(attrs_list) do
    regime = tax_regime()
    definitions = CustomFields.active_definitions("client")

    attrs_list
    |> insert_all_or_none(regime, definitions)
    |> case do
      {:ok, clients} ->
        Events.broadcast(Events.clients_topic(), {:clients_imported, length(clients)})
        Enum.each(clients, &Webhooks.publish("client.created", &1.id))

        Audit.log_event(:import_clients, "Client", nil,
          user_id: Keyword.get(opts, :user_id),
          details: %{count: length(clients), file: Keyword.get(opts, :file)}
        )

        {:ok, clients}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  defp insert_all_or_none([], _regime, _definitions), do: {:ok, []}

  defp insert_all_or_none(attrs_list, regime, definitions) do
    Repo.transaction(fn ->
      Enum.map(attrs_list, fn attrs ->
        case attrs |> Import.changeset(regime, definitions) |> Repo.insert() do
          {:ok, client} -> client
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # The business's regime decides which tax identity a client needs.
  defp tax_regime,
    do:
      QuantumBilling.Settings.get_organization()
      |> QuantumBilling.Settings.Organization.tax_regime()

  defp announce({:ok, client} = result, event) do
    Events.broadcast(Events.clients_topic(), {event, client})

    case event do
      :client_created -> Webhooks.publish("client.created", client.id)
      :client_updated -> Webhooks.publish("client.updated", client.id)
      _other -> :ok
    end

    result
  end

  defp announce({:error, _changeset} = result, _event), do: result

  @doc """
  Moves a client to the Bin. Its records stay; its recurring profiles pause.

  `opts` may carry `:user_id` for the audit entry.
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

  @doc "Restores a client. Returns `{:error, :gstin_taken}` if another now has its GSTIN."
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
  Deletes a binned client for good.

  Returns `{:error, :not_in_bin}`, or `{:error, :in_use}` while it has credit notes.
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

  @doc "Whether a client of this type must supply a GSTIN."
  defdelegate gstin_required?(client_type), to: Client

  defdelegate client_types(), to: Client
  defdelegate business_types(), to: Client
  defdelegate categories(), to: Client
  defdelegate country_codes(), to: Client
  defdelegate statuses(), to: Client
end
