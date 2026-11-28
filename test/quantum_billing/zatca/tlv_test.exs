defmodule QuantumBilling.Zatca.TLVTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.Zatca.TLV

  doctest TLV

  test "encodes each field as tag, byte length and value" do
    assert TLV.encode([{1, "Bobs Records"}, {2, "310122393500003"}]) ==
             <<1, 12, "Bobs Records", 2, 15, "310122393500003">>
  end

  test "counts UTF-8 bytes, not characters" do
    name = "شركة ماثل التجريبية"

    assert String.length(name) == 19
    assert <<1, 36, rest::binary>> = TLV.encode([{1, name}])
    assert rest == name
  end

  test "a nil value is an empty field" do
    assert TLV.encode([{2, nil}]) == <<2, 0>>
  end

  test "a value over 255 bytes is cut on a character boundary" do
    # 128 two-byte letters: 256 bytes, one too many.
    long = String.duplicate("ب", 128)

    assert <<1, 254, value::binary>> = TLV.encode([{1, long}])
    assert String.valid?(value)
    assert value == String.duplicate("ب", 127)
  end

  test "decode reverses encode" do
    fields = [{1, "شركة ماثل التجريبية"}, {2, "310122393500003"}, {3, "2022-04-25T15:30:00Z"}]

    assert TLV.decode(TLV.encode(fields)) == {:ok, fields}
  end

  test "decode keeps bytes that are not UTF-8, as Phase 2's key and signature tags carry" do
    der = <<0x30, 0x81, 0xFF, 0x00>>

    assert {:ok, [{8, ^der}]} = TLV.decode(<<8, 4, der::binary>>)
  end

  test "decode refuses a cut-short binary" do
    assert TLV.decode(<<1, 10, "short">>) == :error
  end
end
