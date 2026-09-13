defmodule QuantumBillingWeb.ClientIP do
  @moduledoc """
  Works out who a request actually came from, and whether that address is in a
  list.

  ## Why `x-forwarded-for` is not simply believed

  Anyone can send that header. An IP allowlist that reads it unconditionally is
  not an allowlist: a request from anywhere carrying
  `x-forwarded-for: 127.0.0.1` is admitted, and the same trick turns per-IP
  rate limiting into no rate limiting, since every attempt can claim a
  different source.

  The header is therefore used only when the connection itself comes from a
  proxy the deployment has declared, in `TRUSTED_PROXIES` (a comma-separated
  list of addresses or CIDR blocks). With nothing declared — the default —
  the peer address is used, which is the truth about where the connection came
  from.

  When the header is trusted, the **rightmost** entry that is not itself a
  trusted proxy is taken. Reading left to right takes whatever the client
  chose to prepend; reading from the right walks back through the proxies that
  actually handled the request.
  """

  import Bitwise

  @doc """
  The address a request came from, as a string.
  """
  def client_ip(%Plug.Conn{} = conn) do
    conn
    |> client_ip_tuple()
    |> to_string_ip()
  end

  @doc "The address a request came from, as an `:inet` tuple."
  def client_ip_tuple(%Plug.Conn{remote_ip: remote_ip} = conn) do
    if trusted_proxy?(remote_ip) do
      conn
      |> forwarded_chain()
      |> Enum.reverse()
      |> Enum.find(&(!trusted_proxy?(&1)))
      |> case do
        nil -> remote_ip
        address -> address
      end
    else
      remote_ip
    end
  end

  @doc """
  Whether `address` — a string or an `:inet` tuple — matches any entry in
  `allowed`.

  Entries are single addresses or CIDR blocks, in either IP version. An
  unparseable entry matches nothing rather than everything: a typo in the
  allowlist must not open it up.
  """
  def allowed?(address, allowed) when is_list(allowed) do
    case parse(address) do
      nil -> false
      parsed -> Enum.any?(allowed, &matches?(parsed, String.trim(&1)))
    end
  end

  @doc """
  Whether an address is one of the declared reverse proxies.
  """
  def trusted_proxy?(address) do
    case trusted_proxies() do
      [] -> false
      proxies -> allowed?(address, proxies)
    end
  end

  @doc "The configured proxy list, as written."
  def trusted_proxies do
    :quantum_billing
    |> Application.get_env(:trusted_proxies, [])
    |> List.wrap()
  end

  @doc "Formats an `:inet` address tuple as a string."
  def to_string_ip(address) when is_tuple(address) do
    address |> :inet.ntoa() |> to_string()
  end

  def to_string_ip(address) when is_binary(address), do: address
  def to_string_ip(_address), do: "unknown"

  defp forwarded_chain(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse/1)
    |> Enum.reject(&is_nil/1)
  end

  defp matches?(address, entry) do
    case String.split(entry, "/") do
      [single] ->
        case parse(single) do
          nil -> false
          parsed -> same_family?(parsed, address) and parsed == address
        end

      [network, prefix] ->
        with parsed when not is_nil(parsed) <- parse(network),
             {length, ""} <- Integer.parse(prefix),
             true <- same_family?(parsed, address) do
          in_block?(address, parsed, length)
        else
          _invalid -> false
        end

      _too_many_slashes ->
        false
    end
  end

  defp in_block?(address, network, length) do
    bits = bit_size_for(address)

    if length < 0 or length > bits do
      false
    else
      mask = if length == 0, do: 0, else: bsl(1, bits) - bsl(1, bits - length)
      band(to_integer(address), mask) == band(to_integer(network), mask)
    end
  end

  defp same_family?(a, b), do: tuple_size(a) == tuple_size(b)

  defp bit_size_for(address) when tuple_size(address) == 4, do: 32
  defp bit_size_for(_address), do: 128

  defp to_integer(address) when tuple_size(address) == 4 do
    address |> Tuple.to_list() |> Enum.reduce(0, fn octet, acc -> bsl(acc, 8) + octet end)
  end

  defp to_integer(address) do
    address |> Tuple.to_list() |> Enum.reduce(0, fn group, acc -> bsl(acc, 16) + group end)
  end

  defp parse(address) when is_tuple(address), do: normalize(address)

  defp parse(address) when is_binary(address) do
    case :inet.parse_address(to_charlist(String.trim(address))) do
      {:ok, parsed} -> normalize(parsed)
      {:error, _reason} -> nil
    end
  end

  defp parse(_address), do: nil

  # A dual-stack listener reports IPv4 peers as IPv4-mapped IPv6 addresses
  # (`::ffff:127.0.0.1`). Left as they are, they would never match a plain
  # `127.0.0.1` in an allowlist, and the allowlist would appear simply not to
  # work on exactly the deployments that use one.
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    {bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)}
  end

  defp normalize(address), do: address
end
