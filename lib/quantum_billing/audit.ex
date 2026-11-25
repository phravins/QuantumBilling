defmodule QuantumBilling.Audit do
  @moduledoc """
  The audit trail: who did what to which record, and what changed.

  ## Who acted

  The request or LiveView that does the work names its actor once, with
  `put_actor/1`, next to `Repo.put_business/1` (`UserAuth`, `Plugs.ApiAuth`,
  the payment webhook). `log_event/4` then records that actor and their
  address on every entry the process writes, so contexts need not pass them
  down. An entry written with no actor, by a background job, is the System's.

  ## What changed

  `changes/2` turns a changeset into `%{"field" => %{"from" => .., "to" => ..}}`,
  with secrets (`redact: true` fields) recorded only as changed.
  """
  import Ecto.Query, warn: false
  alias QuantumBilling.Repo
  alias QuantumBilling.Audit.AuditLog

  @actor_key {__MODULE__, :actor}

  # Text values longer than this are cut short in the trail.
  @max_text 300

  @skipped_fields [:inserted_at, :updated_at, :deleted_at, :lock_version]

  ## Actor

  @doc """
  Names who this process acts for, until cleared or replaced.

  Takes a map with any of `:user_id`, `:api_key_id`, `:ip_address`, `:via`
  (`"public_link"` or `"razorpay"` when no member or key acted) and `:name`
  (shown if the member or key is later deleted). `nil` clears it.
  """
  def put_actor(nil), do: clear_actor()

  def put_actor(%{} = actor) do
    actor =
      actor
      |> Map.take([:user_id, :api_key_id, :ip_address, :via, :name])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Process.put(@actor_key, actor)
    actor
  end

  @doc "Who this process acts for, or `nil`."
  def actor, do: Process.get(@actor_key)

  @doc "Forgets who this process acts for."
  def clear_actor do
    Process.delete(@actor_key)
    nil
  end

  ## Writing

  @doc """
  Logs an action.

  Options:

    * `:user_id`, `:api_key_id`, `:ip_address` - who acted; default to the
      process's actor (`put_actor/1`)
    * `:details` - a map stored with the entry
    * `:label` - the record's human name ("INV-0042"), stored as `details["label"]`
    * `:changes` - a `changes/2` map, stored as `details["changes"]`
    * `:merge_within` - minutes: fold this entry into the same actor's last
      entry for the same action and record if it is that recent. For pages
      that save on every keystroke, so one sitting is one entry.
  """
  def log_event(action, resource_type, resource_id \\ nil, opts \\ []) do
    who = who(opts)

    details =
      opts
      |> Keyword.get(:details, %{})
      |> stringify_keys()
      |> put_present("label", Keyword.get(opts, :label))
      |> put_present("changes", present_changes(Keyword.get(opts, :changes)))
      |> put_present("actor", who.name)
      |> put_present("via", who.via)

    attrs = %{
      user_id: who.user_id,
      api_key_id: who.api_key_id,
      action: to_string(action),
      resource_type: to_string(resource_type),
      resource_id: if(is_nil(resource_id), do: nil, else: to_string(resource_id)),
      details: details,
      ip_address: who.ip_address
    }

    case merge_target(attrs, Keyword.get(opts, :merge_within)) do
      %AuditLog{} = previous -> merge(previous, details)
      nil -> insert(attrs)
    end
  end

  @doc """
  Logs `action` for the record in an `{:ok, record}` result and returns the
  result unchanged, so a context can pipe into it. Errors pass through unlogged.

  `opts_fun` receives the record and returns `log_event/4` options, or
  `:skip` to log nothing.
  """
  def record(result, action, resource_type, opts_fun \\ fn _record -> [] end)

  def record({:ok, %{id: id} = record} = result, action, resource_type, opts_fun) do
    case opts_fun.(record) do
      :skip -> :ok
      opts -> log_event(action, resource_type, id, opts)
    end

    result
  end

  def record(result, _action, _resource_type, _opts_fun), do: result

  @doc """
  What a changeset changes, ready for the trail:
  `%{"field" => %{"from" => old, "to" => new}}`.

  Fields marked `redact: true` in the schema appear as `%{"redacted" => true}`,
  never with their values. Timestamps and `deleted_at` are left out.

  Options:

    * `:summarize` - fields recorded only as `%{"changed" => true}`, for
      bulky values such as a template's layout
    * `:skip` - fields left out entirely
  """
  def changes(%Ecto.Changeset{} = changeset, opts \\ []) do
    schema = changeset.data.__struct__
    redacted = redact_fields(schema)
    summarize = Keyword.get(opts, :summarize, [])
    skipped = @skipped_fields ++ Keyword.get(opts, :skip, [])

    Enum.reduce(changeset.changes, %{}, fn {field, new}, acc ->
      old = Map.get(changeset.data, field)

      cond do
        field in skipped -> acc
        field in redacted -> Map.put(acc, to_string(field), %{"redacted" => true})
        field in summarize -> Map.put(acc, to_string(field), %{"changed" => true})
        nested?(new) -> put_nested(acc, field, new)
        plain(old) == plain(new) -> acc
        true -> Map.put(acc, to_string(field), %{"from" => plain(old), "to" => plain(new)})
      end
    end)
  end

  defp redact_fields(schema) do
    if function_exported?(schema, :__schema__, 1), do: schema.__schema__(:redact_fields), else: []
  end

  defp nested?(%Ecto.Changeset{}), do: true
  defp nested?([%Ecto.Changeset{} | _rest]), do: true
  defp nested?(_value), do: false

  # An embedded or associated record: its own field changes.
  defp put_nested(acc, field, %Ecto.Changeset{} = changeset) do
    case changes(changeset) do
      empty when empty == %{} -> acc
      inner -> Map.put(acc, to_string(field), %{"changes" => inner})
    end
  end

  # Line items and other lists: how many were added, removed and changed.
  defp put_nested(acc, field, changesets) do
    counts =
      Enum.reduce(changesets, %{"added" => 0, "removed" => 0, "changed" => 0}, fn
        %Ecto.Changeset{action: :insert}, counts ->
          Map.update!(counts, "added", &(&1 + 1))

        %Ecto.Changeset{action: action}, counts when action in [:delete, :replace] ->
          Map.update!(counts, "removed", &(&1 + 1))

        %Ecto.Changeset{changes: changes}, counts when changes != %{} ->
          Map.update!(counts, "changed", &(&1 + 1))

        _unchanged, counts ->
          counts
      end)

    if Enum.all?(counts, fn {_key, count} -> count == 0 end),
      do: acc,
      else: Map.put(acc, to_string(field), %{"items" => counts})
  end

  # JSON-safe and short.
  defp plain(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp plain(%Date{} = value), do: Date.to_iso8601(value)
  defp plain(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp plain(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp plain(%Time{} = value), do: Time.to_iso8601(value)
  defp plain(%{__struct__: _} = value), do: inspect(value)
  defp plain(value) when is_atom(value) and value not in [nil, true, false], do: to_string(value)

  defp plain(value) when is_binary(value) do
    if String.length(value) > @max_text,
      do: String.slice(value, 0, @max_text) <> "…",
      else: value
  end

  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)

  defp plain(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), plain(v)} end)

  defp plain(value), do: value

  defp who(opts) do
    actor = actor() || %{}
    user_id = Keyword.get(opts, :user_id)
    api_key_id = Keyword.get(opts, :api_key_id)

    if user_id || api_key_id do
      same_actor? =
        (user_id && user_id == actor[:user_id]) ||
          (api_key_id && api_key_id == actor[:api_key_id])

      %{
        user_id: user_id,
        api_key_id: api_key_id,
        ip_address: Keyword.get(opts, :ip_address) || (same_actor? && actor[:ip_address]) || nil,
        name: if(same_actor?, do: actor[:name]),
        via: nil
      }
    else
      %{
        user_id: actor[:user_id],
        api_key_id: actor[:api_key_id],
        ip_address: Keyword.get(opts, :ip_address) || actor[:ip_address],
        name: actor[:name],
        via: actor[:via]
      }
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_other), do: %{}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present_changes(changes) when is_map(changes) and map_size(changes) > 0, do: changes
  defp present_changes(_none), do: nil

  defp insert(attrs) do
    case %AuditLog{} |> AuditLog.changeset(attrs) |> Repo.insert() do
      {:ok, log} ->
        log = Repo.preload(log, [:user, :api_key])
        broadcast({:audit_log_created, log})
        {:ok, log}

      error ->
        error
    end
  end

  defp merge_target(_attrs, nil), do: nil

  defp merge_target(attrs, minutes) when is_integer(minutes) and minutes > 0 do
    since = DateTime.add(DateTime.utc_now(:second), -minutes * 60)

    AuditLog
    |> where([l], l.action == ^attrs.action and l.resource_type == ^attrs.resource_type)
    |> where_equal(:resource_id, attrs.resource_id)
    |> where_equal(:user_id, attrs.user_id)
    |> where_equal(:api_key_id, attrs.api_key_id)
    |> where([l], l.inserted_at >= ^since)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(1)
    |> Repo.one()
  end

  defp where_equal(query, field, nil), do: where(query, [l], is_nil(field(l, ^field)))
  defp where_equal(query, field, value), do: where(query, [l], field(l, ^field) == ^value)

  # Keeps each field's first "from" and takes the newest "to"; a field set
  # back to where it started drops out.
  defp merge(%AuditLog{} = previous, details) do
    old_changes = Map.get(previous.details, "changes", %{})
    new_changes = Map.get(details, "changes", %{})

    changes =
      old_changes
      |> Map.merge(new_changes, fn
        _field, %{"from" => from}, %{"to" => to} -> %{"from" => from, "to" => to}
        _field, _old, new -> new
      end)
      |> Map.reject(fn {_field, change} -> match?(%{"from" => same, "to" => same}, change) end)

    merged =
      previous.details
      |> Map.merge(details)
      |> Map.put("edits", Map.get(previous.details, "edits", 1) + 1)
      |> then(
        &if(changes == %{}, do: Map.delete(&1, "changes"), else: Map.put(&1, "changes", changes))
      )

    previous
    |> Ecto.Changeset.change(details: merged, inserted_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> case do
      {:ok, log} ->
        log = Repo.preload(log, [:user, :api_key], force: true)
        broadcast({:audit_log_updated, log})
        {:ok, log}

      error ->
        error
    end
  end

  defp broadcast(message) do
    QuantumBilling.Events.broadcast(QuantumBilling.Events.audit_logs_topic(), message)
  end

  ## Reading

  @doc """
  Lists audit logs sorted by most recent.
  """
  def list_audit_logs(limit \\ 100) do
    AuditLog
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload([:user, :api_key])
  end

  @doc """
  The newest `limit` actions taken by one user, for their profile page.
  """
  def recent_for_user(user_id, limit \\ 8) do
    AuditLog
    |> where([l], l.user_id == ^user_id)
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "One entry, with who made it, or `nil`."
  def get_log(id) do
    case Repo.get(AuditLog, id) do
      nil -> nil
      log -> Repo.preload(log, [:user, :api_key])
    end
  end

  @doc """
  One page of the audit trail, filtered and counted in the database.

  Returns `%{rows:, total:, page:, per_page:, total_pages:}`.

  Options:

    * `:action`, `:resource_type` - exact; `""` or `nil` for all
    * `:actions` - a list of actions, any of which matches
    * `:user_id` - entries by one member
    * `:actor` - `:api` for entries made with an API key, `:system` for
      entries no member or key made
    * `:from`, `:to` - `DateTime` bounds, inclusive and exclusive
    * `:q` - text searched in the record's name and number
    * `:page`, `:per_page`
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, 50) |> clamp(1, 200)

    query =
      AuditLog
      |> filter_equal(:action, Keyword.get(opts, :action))
      |> filter_equal(:resource_type, Keyword.get(opts, :resource_type))
      |> filter_actions(Keyword.get(opts, :actions))
      |> filter_equal(:user_id, Keyword.get(opts, :user_id))
      |> filter_actor(Keyword.get(opts, :actor))
      |> filter_since(Keyword.get(opts, :from))
      |> filter_before(Keyword.get(opts, :to))
      |> filter_text(Keyword.get(opts, :q))

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(ceil(total / per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> clamp(1, total_pages)

    rows =
      query
      |> order_by([l], desc: l.inserted_at, desc: l.id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> Repo.preload([:user, :api_key])

    %{rows: rows, total: total, page: page, per_page: per_page, total_pages: total_pages}
  end

  # Records with a page of their own, and the field that hides them from it.
  @record_schemas %{
    "Invoice" => {QuantumBilling.Invoices.Invoice, :deleted_at},
    "Quotation" => {QuantumBilling.Quotations.Quotation, :deleted_at},
    "Client" => {QuantumBilling.Clients.Client, :deleted_at},
    "InvoiceTemplate" => {QuantumBilling.Templates.InvoiceTemplate, :archived_at}
  }

  @doc """
  Whether the record an entry is about can still be opened: it exists and is
  not in the Bin. `true` for types without a page of their own.
  """
  def record_open?(resource_type, resource_id) do
    case Map.fetch(@record_schemas, resource_type) do
      {:ok, {schema, hidden_field}} ->
        case Integer.parse(to_string(resource_id)) do
          {id, ""} ->
            Repo.exists?(from r in schema, where: r.id == ^id and is_nil(field(r, ^hidden_field)))

          _not_an_id ->
            false
        end

      :error ->
        true
    end
  end

  @doc "Whether `log` would be listed by `page/1` with these filters."
  def matches?(%AuditLog{} = log, opts) do
    query =
      AuditLog
      |> where([l], l.id == ^log.id)
      |> filter_equal(:action, Keyword.get(opts, :action))
      |> filter_equal(:resource_type, Keyword.get(opts, :resource_type))
      |> filter_actions(Keyword.get(opts, :actions))
      |> filter_equal(:user_id, Keyword.get(opts, :user_id))
      |> filter_actor(Keyword.get(opts, :actor))
      |> filter_since(Keyword.get(opts, :from))
      |> filter_before(Keyword.get(opts, :to))
      |> filter_text(Keyword.get(opts, :q))

    Repo.exists?(query)
  end

  defp filter_equal(query, _field, blank) when blank in [nil, ""], do: query

  defp filter_equal(query, field, value),
    do: where(query, [l], field(l, ^field) == ^value)

  defp filter_actions(query, actions) when is_list(actions) and actions != [],
    do: where(query, [l], l.action in ^actions)

  defp filter_actions(query, _all), do: query

  defp filter_actor(query, :api), do: where(query, [l], not is_nil(l.api_key_id))

  defp filter_actor(query, :system),
    do: where(query, [l], is_nil(l.user_id) and is_nil(l.api_key_id))

  defp filter_actor(query, _anyone), do: query

  defp filter_since(query, %DateTime{} = from), do: where(query, [l], l.inserted_at >= ^from)
  defp filter_since(query, _open), do: query

  defp filter_before(query, %DateTime{} = to), do: where(query, [l], l.inserted_at < ^to)
  defp filter_before(query, _open), do: query

  # Older entries keep the record's name under other keys, so those are searched too.
  defp filter_text(query, text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        query

      text ->
        pattern = "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"

        where(
          query,
          [l],
          fragment(
            "concat_ws(' ', ?->>'label', ?->>'invoice_number', ?->>'number', ?->>'name', ?->>'client_name', ?->>'ewb_number', ?->>'title', ?->>'note_number') ILIKE ?",
            l.details,
            l.details,
            l.details,
            l.details,
            l.details,
            l.details,
            l.details,
            l.details,
            ^pattern
          )
        )
    end
  end

  defp filter_text(query, _none), do: query

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum
end
