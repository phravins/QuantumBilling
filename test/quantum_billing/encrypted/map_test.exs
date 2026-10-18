defmodule QuantumBilling.Encrypted.MapTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Encrypted.Cipher
  alias QuantumBilling.Encrypted.Map, as: EncryptedMap

  test "a map round-trips with string keys" do
    {:ok, stored} = EncryptedMap.dump(%{"amount" => 100, "payment" => %{"id" => "pay_1"}})

    assert {:ok, %{"amount" => 100, "payment" => %{"id" => "pay_1"}}} =
             EncryptedMap.load(stored)
  end

  test "nil passes through" do
    assert {:ok, nil} = EncryptedMap.dump(nil)
    assert {:ok, nil} = EncryptedMap.load(nil)
  end

  test "the stored value does not contain the plaintext" do
    {:ok, stored} = EncryptedMap.dump(%{"email" => "payer@example.com"})

    refute String.contains?(stored, "payer@example.com")
  end

  test "a ciphertext written for another column is not readable" do
    other = Cipher.encrypt(~s({"a":1}), :secrets_encryption_key, "quantum_billing.secret")

    assert EncryptedMap.load(other) == :error
  end

  test "only maps are accepted" do
    assert EncryptedMap.cast("text") == :error
    assert EncryptedMap.dump("text") == :error
  end
end
