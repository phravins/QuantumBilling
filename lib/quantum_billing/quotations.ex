defmodule QuantumBilling.Quotations do
  @moduledoc """
  Quotations (estimates) and their conversion into invoices.

  A quotation is priced and taxed exactly as an invoice (`Invoice.recalculate/1`
  over the same item changeset) and numbered from its own series
  (`quotation_prefix`/`quotation_next_number`), taken in the same transaction
  as the insert. Quotations live in their own table, so no tax figure, GST
  report or GSTR-1 ever reads them.

  Status moves Draft → Sent → Accepted or Declined. Expired is derived (see
  `Quotation.effective_status/2`). An Accepted quotation converts into one
  invoice through `Invoices.create_invoice/2` with `quotation_id:`.

  Writes take an actor first: a `%Scope{}` (a signed-in member), or keyword
  options for the audit row (`user_id:`, `api_key_id:`, `ip_address:`, and
  `via:` for the client's public link). Deleting moves a quotation to the
  Bin; every read here leaves binned ones out unless it says otherwise.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit
  alias QuantumBilling.Compliance
  alias QuantumBilling.CustomFields
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem
  alias QuantumBilling.Money
  alias QuantumBilling.Paging
  alias QuantumBilling.QuotationNotifier
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.Quotations.QuotationItem
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBilling.Webhooks

  # Allowlisted: the sort field comes from the browser.
  @sortable %{
    number: :number,
    client: :client_name,
    quotation_date: :quotation_date,
    valid_until: :valid_until,
    amount: :grand_total
  }

  @default_per_page 10
  @max_per_page 200

  @doc "How long a new quotation stays valid, in days: the business's setting, 30 by default."
  def validity_days(%Organization{quotation_validity_days: days})
      when is_integer(days) and days > 0,
      do: days

  def validity_days(_organization), do: 30

  @doc "The Valid Until date a quotation dated `date` starts with."
  def default_valid_until(%Organization{} = organization, %Date{} = date),
    do: Date.add(date, validity_days(organization))

  @doc "Today where the business is: the day Expired is judged against."
  def today, do: Compliance.local_date()

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

  @doc """
  One page of quotations, newest first by default, with `:invoice` preloaded.

  Options: `:search` (number or client), `:status` (Draft, Sent, Accepted,
  Declined or Expired; Draft and Sent leave the expired ones out), `:today`,
  `:sort_field`, `:sort_dir`, `:page`, `:per_page`, `:count`, and
  `:keyset`/`:before_id` for the API's cursor paging.
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)
    sort_field = Keyword.get(opts, :sort_field, :quotation_date)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)
    today = Keyword.get_lazy(opts, :today, &today/0)

    query =
      Quotation.kept()
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status), today)

    result =
      if Keyword.get(opts, :keyset, false) do
        Paging.keyset(query, Keyword.get(opts, :before_id), per_page)
      else
        Paging.page(query, &order(&1, sort_field, sort_dir),
          page: Keyword.get(opts, :page, 1),
          per_page: per_page,
          count: Keyword.get(opts, :count, false)
        )
      end

    %{result | rows: Repo.preload(result.rows, :invoice)}
  end

  @doc "How many quotations show each status on `today`, Expired included."
  def status_counts(today \\ today()) do
    shown =
      from q in Quotation.kept(),
        select: %{
          status:
            fragment(
              "CASE WHEN ? IN ('Draft', 'Sent') AND ? < ? THEN 'Expired' ELSE ? END",
              q.status,
              q.valid_until,
              type(^today, :date),
              q.status
            )
        }

    from(s in subquery(shown), group_by: s.status, select: {s.status, count()})
    |> Repo.all()
    |> Map.new()
  end

  defp search_where(query, blank) when blank in [nil, ""], do: query

  defp search_where(query, search) do
    pattern = "%" <> String.trim(search) <> "%"
    where(query, [q], ilike(q.number, ^pattern) or ilike(q.client_name, ^pattern))
  end

  defp status_where(query, status, _today) when status in [nil, "", "All", "All Status"],
    do: query

  defp status_where(query, "Expired", today) do
    where(query, [q], q.status in ["Draft", "Sent"] and q.valid_until < ^today)
  end

  defp status_where(query, status, today) when status in ["Draft", "Sent"] do
    where(query, [q], q.status == ^status and q.valid_until >= ^today)
  end

  defp status_where(query, status, _today), do: where(query, [q], q.status == ^status)

  defp order(query, field, direction) do
    column = Map.get(@sortable, field, :quotation_date)
    direction = if direction == :asc, do: :asc, else: :desc

    # The id breaks ties so paging is stable.
    order_by(query, [q], [{^direction, field(q, ^column)}, {^direction, q.id}])
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  @doc "Fetches a quotation (not in the Bin) with its lines and any linked invoice, or `nil`."
  def get_quotation(id) do
    case parse_id(id) do
      {:ok, int_id} -> Quotation.kept() |> Repo.get(int_id) |> with_assocs()
      :error -> nil
    end
  end

  @doc "Fetches a quotation in the Bin, or `nil`."
  def get_deleted_quotation(id) do
    case parse_id(id) do
      {:ok, int_id} -> Quotation.binned() |> Repo.get(int_id) |> with_assocs()
      :error -> nil
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> {:ok, int_id}
      _not_an_id -> :error
    end
  end

  @doc "Quotations in the Bin, most recently deleted first. Takes `limit:`."
  def list_deleted_quotations(opts \\ []) do
    Quotation.binned()
    |> order_by([q], desc: q.deleted_at, desc: q.id)
    |> Paging.bounded(opts)
    |> Repo.all()
  end

  @doc "How many quotations are in the Bin."
  def count_deleted_quotations, do: Repo.aggregate(Quotation.binned(), :count)

  @doc """
  The quotation behind a public link, or `nil`. Binned quotations have no link.
  """
  def get_quotation_by_token(token) when is_binary(token) and token != "" do
    Quotation.kept() |> Repo.get_by(public_token: token) |> with_assocs()
  end

  def get_quotation_by_token(_token), do: nil

  @doc "Gives a quotation saved before public links existed its token; others are returned as they are."
  def ensure_public_token(%Quotation{public_token: token} = quotation)
      when is_binary(token) and token != "",
      do: {:ok, quotation}

  def ensure_public_token(%Quotation{} = quotation) do
    quotation |> Quotation.token_changeset() |> Repo.update()
  end

  @doc "As `get_quotation/1`, but raises when missing."
  def get_quotation!(id) do
    get_quotation(id) || raise Ecto.NoResultsError, queryable: Quotation
  end

  defp with_assocs(nil), do: nil

  defp with_assocs(%Quotation{} = quotation) do
    Repo.preload(
      quotation,
      [items: from(i in QuotationItem, order_by: i.position), invoice: []],
      force: true
    )
  end

  @doc "Builds a changeset for the quotation form."
  def change_quotation(%Quotation{} = quotation \\ %Quotation{}, attrs \\ %{}, trusted \\ %{}) do
    Quotation.changeset(quotation, attrs, trusted)
  end

  @doc """
  The company and tax settings a new quotation would take, for the form's
  live preview. An existing quotation previews only the company.
  """
  def preview_trusted(%Organization{} = organization, %Quotation{id: nil}) do
    organization
    |> Invoices.company_snapshot()
    |> Map.merge(Organization.invoice_tax_snapshot(organization))
  end

  def preview_trusted(%Organization{} = organization, %Quotation{}),
    do: Invoices.company_snapshot(organization)

  @doc "Creates a quotation with the next number in the quotation series."
  def create_quotation(actor, attrs) do
    # Outside the transaction, as for invoices: these reads must not deadlock.
    _organization = Settings.ensure_organization()
    template = Invoices.resolve_template(attrs)

    Multi.new()
    # Locked so two transactions cannot take the same number.
    |> Multi.run(:organization, fn repo, _changes ->
      case repo.one(from o in Organization, order_by: [asc: o.id], limit: 1, lock: "FOR UPDATE") do
        nil -> {:ok, %Organization{}}
        organization -> {:ok, organization}
      end
    end)
    |> Multi.insert(:quotation, fn %{organization: locked} ->
      trusted =
        %{number: Settings.next_quotation_number(locked), user_id: actor_user_id(actor)}
        |> Map.merge(Invoices.company_snapshot(locked))
        |> Map.merge(Invoices.layout_snapshot(template))
        |> Map.put(:default_currency, Organization.currency_code(locked))
        |> Map.merge(Organization.invoice_tax_snapshot(locked))

      Quotation.changeset(%Quotation{}, attrs, trusted)
    end)
    |> Multi.run(:advance_number, fn repo, %{organization: organization} ->
      organization
      |> Ecto.Changeset.change(%{
        quotation_next_number: (organization.quotation_next_number || 1) + 1
      })
      |> repo.insert_or_update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{quotation: quotation}} ->
        audit(:create_quotation, quotation, actor)
        Webhooks.publish("quotation.created", quotation.id)
        {:ok, with_assocs(quotation)}

      {:error, :quotation, changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Updates a Draft or Sent quotation; an Accepted or Declined one is locked
  (`{:error, :locked}`). The number and company block never change; the
  design is re-taken from the form.
  """
  def update_quotation(actor, %Quotation{} = quotation, attrs) do
    if Quotation.editable?(quotation) do
      trusted = attrs |> Invoices.resolve_template() |> Invoices.layout_snapshot()

      Repo.transaction(fn ->
        current =
          Repo.one(
            from q in Quotation.kept(),
              where: q.id == ^quotation.id,
              lock: "FOR UPDATE"
          )

        cond do
          is_nil(current) ->
            Repo.rollback(:not_found)

          not Quotation.editable?(current) ->
            Repo.rollback(:locked)

          true ->
            current
            |> Repo.preload(:items)
            |> Quotation.changeset(attrs, trusted)
            |> Ecto.Changeset.change(
              revision: current.revision + 1,
              status: if(current.status == "Sent", do: "Draft", else: current.status)
            )
            |> Repo.update()
            |> case do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)
      |> case do
        {:ok, quotation} ->
          audit(:update_quotation, quotation, actor)
          Webhooks.publish("quotation.updated", quotation.id)
          broadcast_public(quotation)
          {:ok, with_assocs(quotation)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :locked}
    end
  end

  @doc "Draft → Sent. An expired draft needs a later `valid_until` first."
  def mark_sent(actor, %Quotation{} = quotation) do
    transition(actor, quotation, "Sent", :quotation_sent, fn q ->
      q.status == "Draft" and not expired?(q)
    end)
  end

  @doc "Draft or Sent → Accepted. An expired quotation needs a later `valid_until` first."
  def accept(actor, %Quotation{} = quotation, expected_revision \\ nil) do
    transition(
      actor,
      quotation,
      "Accepted",
      :quotation_accepted,
      fn q -> q.status in ["Draft", "Sent"] and not expired?(q) and Quotation.answerable?(q) end,
      expected_revision
    )
  end

  @doc "Draft or Sent (expired or not) → Declined."
  def decline(actor, %Quotation{} = quotation, expected_revision \\ nil) do
    transition(
      actor,
      quotation,
      "Declined",
      :quotation_declined,
      fn q -> q.status in ["Draft", "Sent"] and Quotation.answerable?(q) end,
      expected_revision
    )
  end

  defp transition(actor, quotation, status, action, allowed?, expected_revision \\ nil) do
    # Re-read under a lock: the page may be showing a stale status, or it was binned.
    Repo.transaction(fn ->
      current =
        Repo.one(from q in Quotation.kept(), where: q.id == ^quotation.id, lock: "FOR UPDATE")

      cond do
        is_nil(current) ->
          Repo.rollback(:not_found)

        not is_nil(expected_revision) and current.revision != expected_revision ->
          Repo.rollback(:stale_revision)

        allowed?.(current) ->
          changeset = Quotation.status_changeset(current, status)

          changeset =
            if status == "Sent",
              do: Ecto.Changeset.change(changeset, sent_revision: current.revision),
              else: changeset

          case Repo.update(changeset) do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end

        true ->
          Repo.rollback(:invalid_transition)
      end
    end)
    |> case do
      {:ok, updated} ->
        extra =
          if status == "Accepted",
            do: %{accepted_revision: updated.revision},
            else: %{}

        audit(action, updated, actor, extra)
        publish_status(status, updated.id)
        broadcast_public(updated)
        {:ok, with_assocs(updated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Spelled out, so a search for an event type finds where it is published.
  defp publish_status("Sent", id), do: Webhooks.publish("quotation.sent", id)
  defp publish_status("Accepted", id), do: Webhooks.publish("quotation.accepted", id)
  defp publish_status("Declined", id), do: Webhooks.publish("quotation.declined", id)

  def subscribe_public(token), do: Events.subscribe(Events.public_quotation_topic(token))

  defp broadcast_public(%Quotation{public_token: token, id: id}) when is_binary(token) do
    Events.broadcast(Events.public_quotation_topic(token), {:quotation_changed, id})
  end

  defp broadcast_public(_quotation), do: :ok

  @doc "Whether `quotation` reads as Expired today."
  def expired?(quotation), do: Quotation.effective_status(quotation, today()) == "Expired"

  @doc """
  Emails the quotation, PDF attached and with the client's link, to
  `recipient`. A draft is marked Sent. An expired quotation is refused
  (`{:error, :expired}`): extend Valid Until first.
  """
  def send_email(actor, %Quotation{} = quotation, recipient) do
    with :ok <- if(expired?(quotation), do: {:error, :expired}, else: :ok),
         {:ok, quotation} <- ensure_public_token(quotation),
         {:ok, delivery} <- QuotationNotifier.deliver_async(recipient, quotation) do
      audit(:email_quotation, quotation, actor, %{to: delivery.to_email})

      quotation =
        case quotation.status do
          "Draft" ->
            case mark_sent(actor, quotation) do
              {:ok, sent} -> sent
              {:error, _reason} -> with_assocs(quotation)
            end

          _other ->
            with_assocs(quotation)
        end

      {:ok, quotation, delivery}
    end
  end

  @doc """
  Moves a quotation to the Bin, unless it has been converted
  (`{:error, :converted}`): the invoice keeps pointing at it.
  """
  def delete_quotation(actor, %Quotation{} = quotation) do
    quotation = Repo.preload(quotation, :invoice, force: true)

    cond do
      Quotation.converted?(quotation) ->
        {:error, :converted}

      not is_nil(quotation.deleted_at) ->
        {:ok, quotation}

      true ->
        case quotation |> Quotation.bin_changeset() |> Repo.update() do
          {:ok, binned} ->
            audit(:delete_quotation, binned, actor)
            {:ok, binned}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc "Takes a quotation out of the Bin."
  def restore_quotation(actor, %Quotation{} = quotation) do
    case quotation |> Quotation.restore_changeset() |> Repo.update() do
      {:ok, restored} ->
        audit(:restore_quotation, restored, actor)
        {:ok, with_assocs(restored)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a binned quotation for good, lines included. One not in the Bin is
  refused (`{:error, :not_in_bin}`).
  """
  def purge_quotation(_actor, %Quotation{deleted_at: nil}), do: {:error, :not_in_bin}

  def purge_quotation(actor, %Quotation{} = quotation) do
    case Repo.delete(quotation) do
      {:ok, purged} ->
        audit(:purge_quotation, purged, actor)
        {:ok, purged}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Whether the quotation can be converted: Accepted, with no invoice yet."
  def convertible?(%Quotation{status: "Accepted"} = quotation) do
    not Quotation.converted?(Repo.preload(quotation, :invoice))
  end

  def convertible?(%Quotation{}), do: false

  @doc """
  The new-invoice form's params for converting `quotation`: client, place of
  supply, currency, design, remarks, terms and lines. Dates come from the
  invoice form's own defaults.
  """
  def invoice_params(%Quotation{} = quotation) do
    quotation = Repo.preload(quotation, :items)
    currency = quotation.currency
    item_carry = carry_fn("quotation_item", "invoice_item", currency)

    %{
      "client_id" => (quotation.client_id && to_string(quotation.client_id)) || "",
      "client_name" => quotation.client_name,
      "client_gstin" => quotation.client_gstin,
      "client_pan" => quotation.client_pan,
      "client_billing_address" => quotation.client_billing_address,
      "client_email" => quotation.client_email,
      "client_state" => quotation.client_state,
      "client_city" => quotation.client_city,
      "client_pincode" => quotation.client_pincode,
      "client_tax_number" => quotation.client_tax_number,
      "place_of_supply" => quotation.place_of_supply,
      "currency" => quotation.currency,
      "reverse_charge" => to_string(quotation.reverse_charge == true),
      "remarks" => quotation.remarks,
      "terms" => quotation.terms,
      "items" =>
        quotation.items
        |> Enum.sort_by(& &1.position)
        |> Enum.with_index()
        |> Map.new(fn {item, index} ->
          {to_string(index), item |> item_params(index, currency) |> put_custom(item_carry, item)}
        end)
    }
    |> maybe_put("template_id", quotation.template_id)
    |> put_custom(carry_fn("quotation", "invoice", currency), quotation)
  end

  # Values of fields the invoice shares by key and type; the rest stay on the quotation.
  defp carry_fn(from_object, to_object, currency) do
    from = CustomFields.active_definitions(from_object)
    to = if from == [], do: [], else: CustomFields.active_definitions(to_object)
    &CustomFields.carry_over(&1, from, to, currency)
  end

  defp put_custom(params, carry, %{custom_fields: values}) do
    case carry.(values || %{}) do
      empty when empty == %{} -> params
      carried -> Map.put(params, "custom_fields", carried)
    end
  end

  defp item_params(%QuotationItem{} = item, index, currency) do
    %{
      "description" => item.description,
      "hsn_sac" => item.hsn_sac,
      "quantity" => Decimal.to_string(item.quantity, :normal),
      "unit" => item.unit,
      "rate" => Money.to_input(item.rate, currency),
      "tax_rate" => to_string(item.tax_rate),
      "position" => to_string(index)
    }
    |> maybe_put("tax_rate_id", item.tax_rate_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))

  @doc """
  The quotation as an unsaved invoice, only for rendering its PDF with the
  invoice designs. Never inserted.
  """
  def as_document(%Quotation{} = quotation) do
    quotation = Repo.preload(quotation, :items)

    %Invoice{
      invoice_type: "Quotation",
      invoice_number: quotation.number,
      invoice_date: quotation.quotation_date,
      due_date: quotation.valid_until,
      place_of_supply: quotation.place_of_supply,
      status: nil,
      currency: quotation.currency,
      client_id: quotation.client_id,
      client_name: quotation.client_name,
      client_gstin: quotation.client_gstin,
      client_pan: quotation.client_pan,
      client_billing_address: quotation.client_billing_address,
      client_email: quotation.client_email,
      client_state: quotation.client_state,
      client_city: quotation.client_city,
      client_pincode: quotation.client_pincode,
      client_tax_number: quotation.client_tax_number,
      company_name: quotation.company_name,
      company_address: quotation.company_address,
      company_gstin: quotation.company_gstin,
      company_state: quotation.company_state,
      company_tax_number: quotation.company_tax_number,
      tax_regime: quotation.tax_regime,
      reverse_charge: quotation.reverse_charge,
      prices_include_tax: quotation.prices_include_tax,
      round_to_whole_units: quotation.round_to_whole_units,
      total_items: quotation.total_items,
      total_quantity: quotation.total_quantity,
      taxable_value: quotation.taxable_value,
      cgst_amount: quotation.cgst_amount,
      sgst_amount: quotation.sgst_amount,
      igst_amount: quotation.igst_amount,
      cess_amount: quotation.cess_amount,
      rc_cgst_amount: quotation.rc_cgst_amount,
      rc_sgst_amount: quotation.rc_sgst_amount,
      rc_igst_amount: quotation.rc_igst_amount,
      rc_cess_amount: quotation.rc_cess_amount,
      vat_amount: quotation.vat_amount,
      tax_breakdown: quotation.tax_breakdown,
      round_off: quotation.round_off,
      grand_total: quotation.grand_total,
      remarks: quotation.remarks,
      terms: quotation.terms,
      template_id: quotation.template_id,
      layout_xml: quotation.layout_xml,
      custom_fields: quotation.custom_fields || %{},
      items: Enum.map(quotation.items, &as_invoice_item/1)
    }
  end

  defp as_invoice_item(%QuotationItem{} = item) do
    %InvoiceItem{
      description: item.description,
      hsn_sac: item.hsn_sac,
      quantity: item.quantity,
      unit: item.unit,
      rate: item.rate,
      tax_rate: item.tax_rate,
      tax_rate_id: item.tax_rate_id,
      tax_rate_bp: item.tax_rate_bp,
      tax_category: item.tax_category,
      tax_name: item.tax_name,
      amount: item.amount,
      position: item.position,
      custom_fields: item.custom_fields || %{}
    }
  end

  defp audit(action, %Quotation{} = quotation, actor, extra \\ %{}) do
    opts = actor_opts(actor)

    details =
      %{
        number: quotation.number,
        client_name: quotation.client_name,
        status: quotation.status,
        grand_total: quotation.grand_total
      }
      |> Map.merge(extra)
      |> then(&if opts[:via], do: Map.put(&1, :via, opts[:via]), else: &1)

    Audit.log_event(action, "Quotation", quotation.id,
      user_id: opts[:user_id],
      api_key_id: opts[:api_key_id],
      ip_address: opts[:ip_address],
      details: details
    )
  end

  defp actor_opts(%Scope{user: user}), do: [user_id: user && user.id]
  defp actor_opts(opts) when is_list(opts), do: opts
  defp actor_opts(_none), do: []

  defp actor_user_id(actor), do: actor |> actor_opts() |> Keyword.get(:user_id)
end
