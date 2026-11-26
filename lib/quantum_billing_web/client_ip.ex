defmodule QuantumBillingWeb.ClientIP do
  @moduledoc """
  The real client address of a request, and allowlist matching.

  `x-forwarded-for` is trusted only when the peer is a proxy listed in
  `TRUSTED_PROXIES` (addresses or CIDRs); otherwise anyone could claim any
  address. When trusted, the rightmost entry that isn't a trusted proxy wins.
  """

  import Bitwise
  require Logger

  @private_networks [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "127.0.0.0/8",
    "fc00::/7",
    "::1/128"
  ]

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
    resolve(remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))
  end

  @doc """
  The address a LiveView's client connected from, as a string, or `nil`.

  Takes the socket's `:peer_data` and `:x_headers` connect info, and trusts
  `x-forwarded-for` under the same rule as `client_ip/1`.
  """
  def from_connect_info(%{address: address}, x_headers) when is_tuple(address) do
    forwarded =
      for {name, value} <- List.wrap(x_headers),
          String.downcase(name) == "x-forwarded-for",
          do: value

    address |> resolve(forwarded) |> to_string_ip()
  end

  def from_connect_info(_peer_data, _x_headers), do: nil

  defp resolve(remote_ip, forwarded) do
    maybe_warn_untrusted_proxy(remote_ip, forwarded)

    resolved =
      if trusted_proxy?(remote_ip) do
        forwarded
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

    normalize(resolved)
  end

  @doc """
  Whether `address` (string or `:inet` tuple) matches an entry in `allowed`.

  Entries are IPv4/IPv6 addresses or CIDRs. An unparseable entry matches nothing.
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
    address |> normalize() |> :inet.ntoa() |> to_string()
  end

  def to_string_ip(address) when is_binary(address) do
    case parse(address) do
      nil -> address
      parsed -> parsed |> normalize() |> :inet.ntoa() |> to_string()
    end
  end

  def to_string_ip(_address), do: "unknown"

  defp forwarded_chain(values) do
    values
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

  # Dual-stack listeners report IPv4 peers as ::ffff:a.b.c.d; unwrap so allowlists match.
  @doc false
  def normalize({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    {bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)}
  end

  def normalize(address), do: address

  defp maybe_warn_untrusted_proxy(remote_ip, forwarded) do
    if trusted_proxies() == [] and has_forwarded_header?(forwarded) do
      normalized_remote = normalize(remote_ip)

      if allowed?(normalized_remote, @private_networks) do
        log_proxy_warning_once(normalized_remote)
      end
    end
  end

  defp has_forwarded_header?(nil), do: false
  defp has_forwarded_header?([]), do: false

  defp has_forwarded_header?(headers) when is_list(headers) do
    Enum.any?(headers, fn h -> is_binary(h) and String.trim(h) != "" end)
  end

  defp has_forwarded_header?(header) when is_binary(header), do: String.trim(header) != ""
  defp has_forwarded_header?(_), do: false

  defp log_proxy_warning_once(peer_ip) do
    case :persistent_term.get({__MODULE__, :proxy_warning_logged}, false) do
      true ->
        :ok

      false ->
        :persistent_term.put({__MODULE__, :proxy_warning_logged}, true)

        Logger.warning(
          "[security] Requests are arriving through a proxy (peer #{to_string_ip(peer_ip)} sends x-forwarded-for) " <>
            "but TRUSTED_PROXIES is empty. Client IPs in the audit log and rate limits will all be the proxy's. " <>
            "Set TRUSTED_PROXIES. See docs/deployment.md."
        )
    end
  end

  @doc false
  def reset_warning_state! do
    try do
      :persistent_term.erase({__MODULE__, :proxy_warning_logged})
    rescue
      _ -> :ok
    end
  end
end
