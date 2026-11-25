defmodule QuantumBilling.InstallationSettings do
  @moduledoc """
  The sign-in rules, which protect the whole installation rather than one
  business: the IP allowlist, the idle timeout, mandatory two-factor and one
  device at a time. Also
  the super admin's switches: maintenance mode and the main sidebar's layout.

  They apply before anyone has chosen a business — on the sign-in page itself —
  so they cannot live with a business's own settings. There is one row.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias QuantumBilling.Repo

  @schema_prefix "public"
  schema "installation_settings" do
    field :allowed_ips, :string
    field :session_timeout_minutes, :integer, default: 60
    field :enforce_2fa, :boolean, default: false
    # One device at a time: a new sign-in waits for the signed-in device to allow it.
    field :single_session, :boolean, default: false
    field :singleton, :boolean, default: true
    # Set by the super admin only, never through the Security form.
    field :maintenance_mode, :boolean, default: false
    # %{"items" => [%{"key" => "invoices", "hidden" => false}, ...]}
    field :nav_layout, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @fields ~w(allowed_ips session_timeout_minutes enforce_2fa single_session)a

  @doc "The fields that hold the rules."
  def fields, do: @fields

  @doc "The rules in force; the defaults when none have been saved."
  def get do
    Repo.one(from s in __MODULE__, where: s.singleton) || %__MODULE__{}
  end

  @doc "A changeset for the Security settings form."
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_number(:session_timeout_minutes, greater_than: 0, less_than_or_equal_to: 10_080)
    |> QuantumBilling.Settings.Organization.validate_allowed_ips()
  end

  @doc "Saves the rules."
  def update(%__MODULE__{} = settings, attrs) do
    settings
    |> changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Whether maintenance mode is on, so only super admins may use the app."
  def maintenance?, do: get().maintenance_mode == true

  @doc "Turns maintenance mode on or off."
  def set_maintenance(%__MODULE__{} = settings, on?) when is_boolean(on?) do
    settings
    |> change(maintenance_mode: on?)
    |> Repo.insert_or_update()
  end

  @doc """
  Saves the main sidebar's order and hidden items: a list of
  `%{"key" => key, "hidden" => boolean}`, in display order.
  """
  def update_layout(%__MODULE__{} = settings, items) when is_list(items) do
    items =
      for %{"key" => key} = item <- items, is_binary(key) do
        %{"key" => key, "hidden" => item["hidden"] == true}
      end

    result =
      settings
      |> change(nav_layout: %{"items" => items})
      |> Repo.insert_or_update()

    clear_layout_cache()
    result
  end

  @layout_key {__MODULE__, :nav_layout}

  @doc """
  The saved sidebar layout as a list of `%{"key", "hidden"}` maps; `[]` when
  none has been saved. Cached, because the sidebar renders on every change.
  """
  def nav_layout do
    case :persistent_term.get(@layout_key, :none) do
      :none ->
        items = Map.get(get().nav_layout || %{}, "items", [])
        :persistent_term.put(@layout_key, items)
        items

      items ->
        items
    end
  end

  @doc "Forgets the cached sidebar layout, so the next read comes from the database."
  def clear_layout_cache, do: :persistent_term.erase(@layout_key)
end
