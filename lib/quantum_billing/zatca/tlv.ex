defmodule QuantumBilling.Zatca.TLV do
  @moduledoc """
  The tag-length-value encoding of ZATCA's invoice QR code.

  Each field is one tag byte, one length byte and the value's bytes. The
  length counts UTF-8 bytes, not characters: «شركة» is 4 characters and 8
  bytes. A length byte holds at most 255, so a longer value is cut at the last
  whole character that fits, and stays valid UTF-8.
  """

  @max_length 255

  @doc """
  Encodes `[{tag, value}]` in order. A `nil` value is encoded as empty.

  ## Examples

      iex> QuantumBilling.Zatca.TLV.encode([{1, "Bobs"}, {2, "300"}])
      <<1, 4, "Bobs", 2, 3, "300">>

  """
  def encode(fields) when is_list(fields) do
    for {tag, value} <- fields, into: <<>> do
      value = fit(value || "")
      <<tag::8, byte_size(value)::8, value::binary>>
    end
  end

  @doc """
  Decodes a TLV binary into `[{tag, bytes}]`.

  Values are returned as raw bytes and never checked as UTF-8, because tags 8
  and 9 of Phase 2 carry a public key and a signature. Returns `:error` when
  the binary is cut short.
  """
  def decode(binary) when is_binary(binary), do: decode(binary, [])

  defp decode(<<>>, fields), do: {:ok, Enum.reverse(fields)}

  defp decode(<<tag::8, length::8, value::binary-size(length), rest::binary>>, fields),
    do: decode(rest, [{tag, value} | fields])

  defp decode(_truncated, _fields), do: :error

  @doc """
  `value` cut to at most 255 bytes, on a character boundary.

  ## Examples

      iex> QuantumBilling.Zatca.TLV.fit("short")
      "short"

  """
  def fit(value) when is_binary(value) and byte_size(value) <= @max_length, do: value

  def fit(value) when is_binary(value) do
    value
    |> String.codepoints()
    |> Enum.reduce_while({<<>>, 0}, fn codepoint, {kept, size} ->
      size = size + byte_size(codepoint)
      if size <= @max_length, do: {:cont, {kept <> codepoint, size}}, else: {:halt, {kept, size}}
    end)
    |> elem(0)
  end
end
