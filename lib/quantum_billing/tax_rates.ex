defmodule QuantumBilling.TaxRates do
  @moduledoc """
  The VAT rates a business charges. Only owners change them, and every change
  is audited. Invoice lines snapshot a rate when it is chosen, so editing or
  archiving one never changes an issued invoice.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit
  alias QuantumBilling.Repo
  alias QuantumBilling.Tax
  alias QuantumBilling.TaxRates.TaxRate

  @max_active 50

  @doc "Rates in position order. `archived:` is `:exclude` (default), `:only` or `:include`."
  def list_rates(opts \\ []) do
    query = from r in TaxRate, order_by: [asc: r.position, asc: r.id]

    query =
      case Keyword.get(opts, :archived, :exclude) do
        :exclude -> where(query, [r], is_nil(r.archived_at))
        :only -> where(query, [r], not is_nil(r.archived_at))
        :include -> query
      end

    Repo.all(query)
  end

  @doc "Every rate by id, archived ones included: an invoice may still carry one."
  def rates_by_id, do: [archived: :include] |> list_rates() |> Map.new(&{&1.id, &1})

  @doc "The rate new invoice lines start with, or the first active one."
  def default_rate do
    rates = list_rates()
    Enum.find(rates, & &1.is_default) || List.first(rates)
  end

  def get_rate!(id), do: Repo.get!(TaxRate, id)

  def change_rate(%TaxRate{} = rate, attrs \\ %{}),
    do: TaxRate.changeset(TaxRate.with_percent(rate), attrs)

  ## Owners only

  def create_rate(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope),
         :ok <- check_room() do
      %TaxRate{position: next_position()}
      |> TaxRate.changeset(attrs)
      |> Repo.insert()
      |> audited(scope, :tax_rate_created)
    end
  end

  def update_rate(%Scope{} = scope, %TaxRate{} = rate, attrs) do
    with :ok <- authorize(scope) do
      rate
      |> TaxRate.with_percent()
      |> TaxRate.changeset(attrs)
      |> Repo.update()
      |> audited(scope, :tax_rate_updated)
    end
  end

  @doc "Hides a rate from new lines. Invoices that used it keep their snapshot."
  def archive_rate(%Scope{} = scope, %TaxRate{} = rate) do
    with :ok <- authorize(scope) do
      rate
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second), is_default: false)
      |> Repo.update()
      |> audited(scope, :tax_rate_archived)
    end
  end

  def restore_rate(%Scope{} = scope, %TaxRate{} = rate) do
    with :ok <- authorize(scope),
         :ok <- check_room() do
      rate
      |> Ecto.Changeset.change(archived_at: nil, position: next_position())
      |> Repo.update()
      |> audited(scope, :tax_rate_restored)
    end
  end

  @doc "Makes `rate` the one new lines start with."
  def set_default(%Scope{} = scope, %TaxRate{archived_at: nil} = rate) do
    with :ok <- authorize(scope) do
      Repo.transaction(fn ->
        Repo.update_all(from(r in TaxRate, where: r.is_default), set: [is_default: false])
        rate |> Ecto.Changeset.change(is_default: true) |> Repo.update!()
      end)
      |> audited(scope, :tax_rate_default_set)
    end
  end

  def set_default(%Scope{}, %TaxRate{}), do: {:error, :archived}

  @doc """
  Adds `country`'s preset rates when the business has none yet; the first
  taxed one becomes the default. Returns the active rates.
  """
  def ensure_presets(%Scope{} = scope, country) do
    with :ok <- authorize(scope) do
      if list_rates(archived: :include) == [] do
        now = DateTime.utc_now(:second)

        rows =
          country
          |> Tax.presets()
          |> Enum.with_index()
          |> Enum.map(fn {{name, category, rate_bp}, position} ->
            %{
              name: name,
              category: category,
              rate_bp: rate_bp,
              is_default: position == 0,
              position: position,
              inserted_at: now,
              updated_at: now
            }
          end)

        Repo.insert_all(TaxRate, rows)

        Audit.log_event(:tax_rates_preset_added, "TaxRate", nil,
          user_id: scope.user.id,
          details: %{"country" => country, "count" => length(rows)}
        )
      end

      {:ok, list_rates()}
    end
  end

  defp authorize(scope), do: if(Scope.owner?(scope), do: :ok, else: {:error, :unauthorized})

  defp check_room do
    count = Repo.aggregate(from(r in TaxRate, where: is_nil(r.archived_at)), :count)
    if count < @max_active, do: :ok, else: {:error, :limit_reached}
  end

  defp next_position do
    (Repo.one(from r in TaxRate, select: max(r.position)) || -1) + 1
  end

  defp audited({:ok, %TaxRate{} = rate} = result, scope, action) do
    Audit.log_event(action, "TaxRate", rate.id,
      user_id: scope.user.id,
      details: %{
        "name" => rate.name,
        "category" => rate.category,
        "rate_bp" => rate.rate_bp
      }
    )

    result
  end

  defp audited(error, _scope, _action), do: error
end
