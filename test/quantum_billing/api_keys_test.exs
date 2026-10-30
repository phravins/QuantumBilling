defmodule QuantumBilling.ApiKeysTest do
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.ApiKeys
  alias QuantumBilling.ApiKeys.ApiKey
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
