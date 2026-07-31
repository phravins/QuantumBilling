defmodule QuantumBilling.Encrypted.BinaryTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Encrypted.Binary

  describe "round trip" do
    test "what goes in comes back out" do
      secret = NimbleTOTP.secret()

      {:ok, stored} = Binary.dump(secret)
      assert {:ok, ^secret} = Binary.load(stored)
    end

    test "nil passes through" do
      assert {:ok, nil} = Binary.dump(nil)
      assert {:ok, nil} = Binary.load(nil)
    end

    test "handles values of any length" do
      for value <- ["", "a", String.duplicate("x", 5_000)] do
        {:ok, stored} = Binary.dump(value)
        assert {:ok, ^value} = Binary.load(stored)
      end
    end
  end

  describe "confidentiality" do
    test "the stored value does not contain the plaintext" do
      secret = "a-recognisable-secret"

      {:ok, stored} = Binary.dump(secret)

      refute String.contains?(stored, secret)
    end

    test "encrypting the same value twice gives different ciphertext" do
      # A fixed IV would let anyone reading the column tell which accounts share
      # a secret, and would be a serious weakness in GCM specifically.
      secret = NimbleTOTP.secret()

      {:ok, first} = Binary.dump(secret)
      {:ok, second} = Binary.dump(secret)

      refute first == second
      assert {:ok, ^secret} = Binary.load(first)
      assert {:ok, ^secret} = Binary.load(second)
    end
  end

  describe "integrity" do
    test "a tampered value fails rather than decrypting to something else" do
      {:ok, stored} = Binary.dump(NimbleTOTP.secret())

      <<head::binary-size(32), byte, rest::binary>> = stored
      tampered = head <> <<Bitwise.bxor(byte, 1)>> <> rest

      assert Binary.load(tampered) == :error
    end

    test "a tampered authentication tag fails" do
      {:ok, stored} = Binary.dump(NimbleTOTP.secret())

      <<iv::binary-size(16), tag_byte, tag_rest::binary-size(15), body::binary>> = stored
      tampered = iv <> <<Bitwise.bxor(tag_byte, 1)>> <> tag_rest <> body

      assert Binary.load(tampered) == :error
    end

    test "something that was never written by this type fails" do
      assert Binary.load("nonsense") == :error
      assert Binary.load(<<0>>) == :error
    end
  end

  describe "cast/1" do
    test "accepts binaries and nil, rejects the rest" do
      assert {:ok, "abc"} = Binary.cast("abc")
      assert {:ok, nil} = Binary.cast(nil)
      assert :error = Binary.cast(123)
    end
  end
end
