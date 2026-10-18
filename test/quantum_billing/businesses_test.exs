defmodule QuantumBilling.BusinessesTest do
  @moduledoc """
  Several businesses on one installation: each sees only its own records, and
  a business made today is built exactly like the one the old data became.
  """
  # Not async: each test builds a schema, and DDL takes catalogue locks that
  # concurrent sandboxes would queue on.
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Businesses
  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Notifications
  alias QuantumBilling.Recurring
  alias QuantumBilling.Reports
  alias QuantumBilling.Settings

  setup do
    owner = owner_fixture()
    {:ok, other} = Businesses.create(owner, %{"name" => "Firm Two", "gstin" => "29AAACT1234B1Z5"})
    %{owner: owner, first: Businesses.default!(), other: other}
  end

  defp client_fixture(attrs) do
    {:ok, client} =
      Clients.create_client(
        Map.merge(
          %{
            client_type: "Registered Business",
            name: "Acme Corp",
            gstin: "27AAACA1234A1Z5",
            phone: "9876543210",
            email: "billing@acme.test",
            billing_line1: "Main St",
            billing_city: "Mumbai",
            billing_state: "Maharashtra (27)",
            billing_pin: "400001"
          },
          attrs
        )
      )

    client
  end

  defp invoice_fixture(attrs) do
    Repo.insert!(
      struct(
        %Invoice{},
        Map.merge(
          %{
            invoice_number: "INV-0001",
            invoice_date: Date.utc_today(),
            place_of_supply: "Maharashtra (27)",
            company_state: "Maharashtra (27)",
            client_name: "Acme Corp",
            taxable_value: 100_000,
            cgst_amount: 9_000,
            sgst_amount: 9_000,
            igst_amount: 0,
            cess_amount: 0,
            grand_total: 118_000,
            status: "Draft",
            public_token: "tok-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )
    )
  end

  describe "create/2" do
    test "builds a business its creator owns, with its own settings", %{
      owner: owner,
      other: other
    } do
      assert other.schema == "biz_#{other.id}"
      assert other.slug == "firm-two"
      assert role(owner, other) == "owner"

      Repo.with_business(other, fn ->
        organization = Settings.get_organization()
        assert organization.company_name == "Firm Two"
        assert organization.gstin == "29AAACT1234B1Z5"
      end)

      # Business 1's settings are untouched.
      refute Settings.get_organization().company_name == "Firm Two"
    end

    test "a blank name leaves nothing behind", %{owner: owner} do
      before = length(Businesses.list_active())

      assert {:error, %Ecto.Changeset{}} = Businesses.create(owner, %{"name" => "  "})
      assert length(Businesses.list_active()) == before
    end

    test "a second business with the same name gets a slug of its own", %{owner: owner} do
      {:ok, again} = Businesses.create(owner, %{"name" => "Firm Two"})
      assert again.slug == "firm-two-2"
    end
  end

  describe "isolation" do
    test "each business sees only its own clients and invoices", %{other: other} do
      client_fixture(%{email: "one@acme.test"})
      invoice_fixture(%{client_name: "Only In One"})

      # The same GSTIN and invoice number again: uniqueness is per business.
      Repo.with_business(other, fn ->
        client_fixture(%{email: "two@acme.test"})
        invoice_fixture(%{client_name: "Only In Two"})
      end)

      first_emails = Enum.map(Clients.list_clients(), & &1.email)
      assert "one@acme.test" in first_emails
      refute "two@acme.test" in first_emails

      first_names = Enum.map(Invoices.list_invoices(), & &1.client)
      assert "Only In One" in first_names
      refute "Only In Two" in first_names

      Repo.with_business(other, fn ->
        assert Enum.map(Clients.list_clients(), & &1.email) == ["two@acme.test"]
        assert Enum.map(Invoices.list_invoices(), & &1.client) == ["Only In Two"]
      end)
    end

    test "raw SQL reports read the current business only", %{other: other} do
      invoice_fixture(%{client_name: "Only In One"})
      Repo.with_business(other, fn -> invoice_fixture(%{client_name: "Only In Two"}) end)

      names = inspect(Reports.client_names())
      assert names =~ "Only In One"
      refute names =~ "Only In Two"

      other_names = Repo.with_business(other, fn -> inspect(Reports.client_names()) end)
      assert other_names =~ "Only In Two"
      refute other_names =~ "Only In One"
    end

    test "notifications stay in their business", %{other: other} do
      Repo.with_business(other, fn ->
        {:ok, _} =
          Notifications.notify(%{kind: "system", severity: "info", title: "Only for two"})
      end)

      refute Enum.any?(Notifications.recent(), &(&1.title == "Only for two"))

      assert Repo.with_business(other, fn ->
               Enum.any?(Notifications.recent(), &(&1.title == "Only for two"))
             end)
    end

    test "a page in one business hears nothing from another", %{other: other} do
      :ok = Events.subscribe(Events.clients_topic())

      Repo.with_business(other, fn -> client_fixture(%{email: "two@acme.test"}) end)
      refute_receive {_event, %Client{}}, 100

      client_fixture(%{email: "one@acme.test"})
      assert_receive {_event, %Client{email: "one@acme.test"}}
    end
  end

  describe "the leak guard" do
    test "a business table cannot be read with no business chosen" do
      Repo.with_business(nil, fn ->
        assert_raise QuantumBilling.Repo.NoBusinessError, fn -> Repo.all(Invoice) end
      end)
    end

    # Ecto marks the task a migration runs in; its data queries follow the
    # migration's prefix instead of tripping the guard.
    test "a migration's queries go where the migration does", %{other: other} do
      Repo.with_business(other, fn -> client_fixture(%{}) end)

      Repo.with_business(nil, fn ->
        Process.put(:ecto_migration, %{runner: nil, prefix: other.schema})

        try do
          assert Repo.one(from(c in "clients", select: count())) == 1
        after
          Process.delete(:ecto_migration)
        end
      end)
    end

    test "accounts are written to public whichever business is current", %{other: other} do
      user = Repo.with_business(other, fn -> user_fixture() end)

      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*)::int FROM public.users WHERE id = $1", [user.id])

      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'users')",
                 [other.schema]
               )
    end
  end

  describe "structure" do
    # Business 1 was moved out of `public`; every later one is built from the
    # baseline and the tenant migrations. They must come out the same.
    test "a new business is built exactly like the first", %{first: first, other: other} do
      assert structure(other.schema) == structure(first.schema)
    end

    defp structure(schema) do
      [
        """
        SELECT table_name, column_name, data_type, is_nullable,
               replace(coalesce(column_default, ''), $1 || '.', '')
        FROM information_schema.columns WHERE table_schema = $1
        """,
        "SELECT tablename, indexname, replace(indexdef, $1 || '.', '') FROM pg_indexes WHERE schemaname = $1",
        """
        SELECT cl.relname, c.conname, replace(pg_get_constraintdef(c.oid), $1 || '.', '')
        FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        JOIN pg_class cl ON cl.oid = c.conrelid
        WHERE n.nspname = $1
        """
      ]
      |> Enum.map(fn sql -> Repo.query!(sql, [schema]).rows |> Enum.sort() end)
    end
  end

  describe "owner tools" do
    test "an owner renames a business; its slug stays", %{owner: owner, other: other} do
      assert {:ok, renamed} = Businesses.rename(owner, other, %{"name" => "Firm Deux"})
      assert renamed.name == "Firm Deux"
      assert renamed.slug == "firm-two"
    end

    test "someone who does not own it cannot rename or archive it", %{other: other} do
      staff = user_fixture()
      {:ok, _} = Businesses.put_membership(staff, other, "staff")

      assert {:error, :unauthorized} = Businesses.rename(staff, other, %{"name" => "Mine"})
      assert {:error, :unauthorized} = Businesses.archive(staff, other)
    end

    test "the first business cannot be archived", %{owner: owner, first: first} do
      assert {:error, :first_business} = Businesses.archive(owner, first)
    end

    test "archiving hides a business, and restoring brings it back", %{owner: owner, other: other} do
      assert {:ok, archived} = Businesses.archive(owner, other)

      refute other.id in Enum.map(Businesses.list_active(), & &1.id)
      refute other.id in Enum.map(Businesses.list_for_user(owner), fn {b, _m} -> b.id end)
      assert Businesses.get_membership(owner, other.id) == nil
      assert Businesses.get_by_slug(other.slug) == nil
      assert [%{id: id}] = Businesses.list_archived_owned(owner)
      assert id == other.id

      assert {:ok, _restored} = Businesses.restore(owner, archived)
      assert other.id in Enum.map(Businesses.list_active(), & &1.id)
      assert Businesses.list_archived_owned(owner) == []
    end
  end

  describe "background work" do
    test "a recurring profile in one business bills in that business", %{other: other} do
      Repo.with_business(other, fn ->
        client = client_fixture(%{})

        {:ok, _profile} =
          Recurring.create_profile(%{
            title: "Firm Two Retainer",
            frequency: "Monthly",
            next_run_date: Date.utc_today(),
            client_id: client.id,
            auto_send_email: false
          })

        # Inline in tests: the profile job runs here, carrying the business.
        assert Recurring.enqueue_due_profiles() == 1
        assert [invoice] = Repo.all(Invoice)
        assert invoice.remarks =~ "Firm Two Retainer"
      end)

      refute Enum.any?(Repo.all(Invoice), &((&1.remarks || "") =~ "Firm Two Retainer"))
    end
  end
end
