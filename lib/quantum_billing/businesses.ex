defmodule QuantumBilling.Businesses do
  @moduledoc """
  The firms kept on this installation, and who may work in each.

  A business's records live in a Postgres schema of its own; see
  `QuantumBilling.Repo` for how the current one is chosen. This module creates
  those schemas and keeps the `public` rows that describe them.
  """
  import Ecto.Query

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.Business
  alias QuantumBilling.Businesses.Membership
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates

  @doc "The business with `id`, or `nil`."
  def get(id), do: Repo.get(Business, id)

  @doc "The business with `id`. Raises when there is none."
  def get!(id), do: Repo.get!(Business, id)

  @doc "The active business with `slug`, or `nil`."
  def get_by_slug(slug) when is_binary(slug) do
    Repo.one(from b in Business, where: b.slug == ^slug and is_nil(b.archived_at))
  end

  @doc """
  The business a public link or webhook URL names by its slug, or `nil`.

  Links handed out before there were several businesses carry no slug; they
  lead to the first business, where their invoices are.
  """
  def from_link(nil), do: default!()
  def from_link(slug) when is_binary(slug), do: get_by_slug(slug)

  @doc """
  The first business: the one an installation's existing data became, and where
  links and jobs from before there were several businesses still lead.
  """
  def default!, do: get!(1)

  @doc "Every business that is not archived, oldest first."
  def list_active do
    Repo.all(from b in Business, where: is_nil(b.archived_at), order_by: [asc: b.id])
  end

  @doc "The businesses `user` belongs to, oldest first, with their memberships."
  def list_for_user(%User{id: user_id}) do
    Repo.all(
      from b in Business,
        join: m in Membership,
        on: m.business_id == b.id and m.user_id == ^user_id,
        where: is_nil(b.archived_at),
        order_by: [asc: b.id],
        select: {b, m}
    )
  end

  @doc """
  `user`'s membership in the business with `business_id`, with the business
  preloaded — `nil` when they are not a member or it is archived.
  """
  def get_membership(%User{id: user_id}, business_id) do
    Repo.one(
      from m in Membership,
        join: b in assoc(m, :business),
        where: m.user_id == ^user_id and m.business_id == ^business_id,
        where: is_nil(b.archived_at),
        preload: [business: b]
    )
  end

  @doc "Whether `user` owns at least one active business."
  def owns_any?(%User{id: user_id}) do
    Repo.exists?(
      from m in Membership,
        join: b in assoc(m, :business),
        where: m.user_id == ^user_id and m.role == "owner" and is_nil(b.archived_at)
    )
  end

  @doc "The archived businesses `user` owns, most recently archived first."
  def list_archived_owned(%User{id: user_id}) do
    Repo.all(
      from b in Business,
        join: m in Membership,
        on: m.business_id == b.id and m.user_id == ^user_id and m.role == "owner",
        where: not is_nil(b.archived_at),
        order_by: [desc: b.archived_at, desc: b.id]
    )
  end

  @doc """
  Renames `business`, which `user` must own. Only the name changes: the slug is
  in payment links already handed out.
  """
  def rename(%User{} = user, %Business{} = business, attrs) do
    with :ok <- authorize_owner(user, business) do
      business
      |> Business.name_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Archives `business`, which `user` must own: it leaves every picker and is no
  longer swept by the daily jobs, and its records stay where they are.

  The first business cannot be archived. Payment links and jobs from before
  there were several businesses lead there, and must keep working.
  """
  def archive(%User{}, %Business{id: 1}), do: {:error, :first_business}

  def archive(%User{} = user, %Business{} = business) do
    with :ok <- authorize_owner(user, business) do
      business
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
      |> Repo.update()
    end
  end

  @doc "Brings an archived `business`, which `user` owns, back into use."
  def restore(%User{} = user, %Business{} = business) do
    with :ok <- authorize_owner(user, business) do
      business
      |> Ecto.Changeset.change(archived_at: nil)
      |> Repo.update()
    end
  end

  # Archived or not: restoring needs the owner of an archived business.
  defp authorize_owner(%User{id: user_id}, %Business{id: business_id}) do
    owner? =
      Repo.exists?(
        from m in Membership,
          where: m.user_id == ^user_id and m.business_id == ^business_id and m.role == "owner"
      )

    if owner?, do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  Adds `user` to `business` as `role`, or changes their role if they are
  already a member.
  """
  def put_membership(%User{} = user, %Business{} = business, role) do
    %Membership{user_id: user.id, business_id: business.id}
    |> Membership.changeset(role)
    |> Repo.insert(
      on_conflict: [set: [role: role, updated_at: DateTime.utc_now(:second)]],
      conflict_target: [:user_id, :business_id],
      returning: true
    )
  end

  @doc """
  Creates a business owned by `creator`: its row, its schema and tables, its
  settings and default invoice template.

  `attrs` takes `"name"` and, optionally, `"gstin"`. Returns `{:ok, business}`,
  or `{:error, changeset}` — a `Business` changeset for the name, an
  `Organization` one for the GSTIN.

  The tables are built by the tenant migrator, which works in processes and
  transactions of its own, so this cannot be one transaction. Instead each step
  that fails undoes the ones before it: the schema is dropped and the row
  deleted, and nothing half-made is left behind.
  """
  def create(%User{} = creator, attrs) do
    with {:ok, business} <- insert_business(attrs) do
      try do
        build_schema!(business)

        case Repo.with_business(business, fn -> seed(business, creator, attrs) end) do
          :ok ->
            {:ok, business}

          {:error, changeset} ->
            discard!(business)
            {:error, changeset}
        end
      rescue
        error ->
          discard!(business)
          reraise error, __STACKTRACE__
      end
    end
  end

  defp insert_business(attrs) do
    changeset = Business.name_changeset(%Business{}, attrs)

    if changeset.valid? do
      Repo.transaction(fn ->
        %{rows: [[id]]} =
          Repo.query!("SELECT nextval(pg_get_serial_sequence('public.businesses', 'id'))")

        schema = "biz_#{id}"

        business =
          changeset
          |> Ecto.Changeset.change(
            id: id,
            schema: schema,
            slug: free_slug(Ecto.Changeset.get_field(changeset, :name))
          )
          |> Repo.insert!()

        Repo.query!(~s(CREATE SCHEMA "#{schema}"))
        business
      end)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  # Slugs are never reused, archived businesses included: an old payment link
  # must not start leading to a different firm.
  defp free_slug(name) do
    base = Business.slugify(name)

    taken =
      from(b in Business,
        where: b.slug == ^base or like(b.slug, ^"#{base}-%"),
        select: b.slug
      )
      |> Repo.all()
      |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # The migrator compiles the migration files each time it runs; the second
  # business made by one node would otherwise warn that it redefines them.
  defp build_schema!(%Business{schema: schema}) do
    ignoring? = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(
        Repo,
        QuantumBilling.Release.tenant_migrations_path(),
        :up,
        all: true,
        prefix: schema,
        log: false,
        migration_lock: Application.get_env(:quantum_billing, :tenant_migration_lock, true)
      )
    after
      Code.put_compiler_option(:ignore_module_conflict, ignoring?)
    end
  end

  defp seed(%Business{name: name} = business, creator, attrs) do
    organization = Settings.ensure_organization()
    general = %{"company_name" => name, "gstin" => attrs["gstin"] || attrs[:gstin]}

    with {:ok, _organization} <- Settings.update_section(organization, general, :general) do
      Templates.ensure_default()
      {:ok, _membership} = put_membership(creator, business, "owner")
      :ok
    end
  end

  defp discard!(%Business{id: id, schema: "biz_" <> _ = schema}) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
    Repo.delete_all(from b in Business, where: b.id == ^id)
  end
end
