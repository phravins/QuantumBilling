defmodule QuantumBilling.ApiKeysTest do
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.ApiKeys
  alias QuantumBilling.ApiKeys.ApiKey
  alias QuantumBilling.Accounts
  alias QuantumBilling.Businesses

  defp create(attrs) do
    ApiKeys.create_key(
      Map.merge(%{"name" => "Sync", "scopes" => ["invoices:read"]}, attrs),
      owner_fixture(),
      Businesses.default!()
    )
  end

  describe "create_key/2" do
    test "returns the raw key once and stores only its hash" do
      assert {:ok, %{key: key, raw: "qb_live_" <> _ = raw}} = create(%{})

      assert key.hashed_key == ApiKey.hash(raw)
      assert String.starts_with?(raw, key.prefix)
      assert byte_size(key.prefix) < byte_size(raw)
    end

    test "refuses a key with no scopes, or a scope that does not exist" do
      assert {:error, changeset} = create(%{"scopes" => []})
      assert "choose at least one permission" in errors_on(changeset).scopes

      assert {:error, changeset} = create(%{"scopes" => ["invoices:delete"]})
      assert errors_on(changeset).scopes != []
    end

    test "refuses an expiry in the past" do
      assert {:error, changeset} =
               create(%{"expires_at" => DateTime.add(DateTime.utc_now(), -60, :second)})

      assert errors_on(changeset).expires_at != []
    end

    test "refuses issuance after the creator loses owner access" do
      business = Businesses.default!()
      former_owner = owner_fixture()
      _remaining_owner = owner_fixture()
      assert {:ok, _} = Accounts.set_role(business, former_owner, "staff")

      assert {:error, changeset} =
               ApiKeys.create_key(
                 %{"name" => "Too late", "scopes" => ["invoices:read"]},
                 former_owner,
                 business
               )

      assert errors_on(changeset).name == ["only a current business owner can issue API keys"]
      assert ApiKeys.count_active_keys(business, former_owner.id) == 0
    end
  end

  describe "authenticate/1" do
    test "accepts a live key and nothing else" do
      {:ok, %{key: key, raw: raw}} = create(%{})

      assert {:ok, %ApiKey{id: id}} = ApiKeys.authenticate(raw)
      assert id == key.id

      assert ApiKeys.authenticate(raw <> "x") == :error
      assert ApiKeys.authenticate("qb_live_short") == :error
      assert ApiKeys.authenticate("") == :error
      assert ApiKeys.authenticate(nil) == :error
    end

    test "refuses a revoked key, and records who revoked it" do
      owner = owner_fixture()
      {:ok, %{key: key, raw: raw}} = create(%{})

      {:ok, _} = ApiKeys.revoke_key(key, owner)

      assert ApiKeys.authenticate(raw) == :error

      assert Repo.exists?(
               from l in QuantumBilling.Audit.AuditLog,
                 where: l.action == "api_key_revoked" and l.user_id == ^owner.id
             )
    end

    test "demoting a key creator revokes only their keys for that business" do
      business = Businesses.default!()
      former_owner = owner_fixture()
      other_owner = owner_fixture()

      {:ok, %{raw: former_key}} =
        ApiKeys.create_key(%{"name" => "Former", "scopes" => ["invoices:read"]}, former_owner, business)

      {:ok, %{raw: other_key}} =
        ApiKeys.create_key(%{"name" => "Other", "scopes" => ["invoices:read"]}, other_owner, business)

      assert {:ok, _} = Accounts.set_role(business, former_owner, "staff")

      assert ApiKeys.authenticate(former_key) == :error
      assert {:ok, _} = ApiKeys.authenticate(other_key)
    end

    test "removing a member revokes their keys" do
      business = Businesses.default!()
      owner = owner_fixture()
      second_owner = owner_fixture()

      {:ok, %{raw: raw}} =
        ApiKeys.create_key(%{"name" => "Removed", "scopes" => ["invoices:read"]}, owner, business)

      assert {:ok, _} = Accounts.remove_member(business, owner)
      assert ApiKeys.authenticate(raw) == :error
      assert {:ok, _} = Accounts.set_role(business, second_owner, "owner")
    end
  end

  describe "idempotency records" do
    test "are pruned after a day" do
      {:ok, %{key: key}} = create(%{})
      {:proceed, record} = ApiKeys.begin_idempotent(key, "old", "hash")
      {:proceed, _fresh} = ApiKeys.begin_idempotent(key, "new", "hash")

      record
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -2 * 86_400))
      |> Repo.update!()

      assert {:ok, 1} = ApiKeys.prune_idempotency_keys(Businesses.default!())
      assert {:error, :in_progress} = ApiKeys.begin_idempotent(key, "new", "hash")
      assert {:proceed, _} = ApiKeys.begin_idempotent(key, "old", "hash")
    end
  end
end
