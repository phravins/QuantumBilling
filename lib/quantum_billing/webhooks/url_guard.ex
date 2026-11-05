defmodule QuantumBilling.Webhooks.UrlGuard do
  @moduledoc """
  Decides whether this server may POST to a user-supplied webhook URL (SSRF guard).

  `check/1` runs on save and private, loopback and link-local addresses are
  refused. At send time `pin/1` resolves once, checks every address and pins the
  connection to it, which defeats DNS rebinding. Redirects are not followed.
  """

  @doc "`:ok` if this server may POST to `url`, or `{:error, reason}` with a form-ready sentence."
  def check(url) when is_binary(url) do
    with {:ok, %URI{scheme: scheme, host: host, port: port}} <- parse(url),
         :ok <- check_scheme(scheme),
         :ok <- check_host(host),
         {:ok, addresses} <- resolve(host, port),
         :ok <- check_addresses(addresses) do
      :ok
    end
  end

  def check(_url), do: {:error, "must be a full http:// or https:// URL"}

  @doc """
  Resolves `url` once and pins the connection to an address that passed.

  Returns `{:ok, pinned_url, req_options}`; the options keep the original name
  for `Host`, SNI and certificate checks. Unlike `check/1`, an unresolvable name
  is refused.
  """
  def pin(url) when is_binary(url) do
    with {:ok, %URI{scheme: scheme, host: host, port: port} = uri} <- parse(url),
         :ok <- check_scheme(scheme),
         :ok <- check_host(host),
         {:ok, addresses} <- resolve(host, port),
         :ok <- check_addresses(addresses),
         {:ok, address} <- first_address(addresses) do
      pinned = %{uri | host: address |> :inet.ntoa() |> to_string()}
      {:ok, URI.to_string(pinned), [connect_options: [hostname: host]]}
    end
  end

  def pin(_url), do: {:error, "must be a full http:// or https:// URL"}

  # IPv4 first: most hosts serve on it.
  defp first_address([]), do: {:error, "could not be resolved"}

  defp first_address(addresses) do
    {:ok, Enum.find(addresses, &(tuple_size(&1) == 4)) || hd(addresses)}
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, "must be a full http:// or https:// URL"}
    end
  end

  defp check_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_scheme), do: {:error, "must be a full http:// or https:// URL"}

  defp check_host(host) when is_binary(host) and host != "" do
    if String.ends_with?(host, [".internal", ".local", ".localdomain"]) or
         host in ["localhost", "metadata.google.internal"] do
      {:error, "cannot point inside the server's own network"}
    else
      :ok
    end
  end

  defp check_host(_host), do: {:error, "must include a hostname"}

  @resolve_timeout_ms 2_000

  # An unresolvable name is allowed here; `pin/1` refuses it at send time.
  # The resolver is configurable so tests don't depend on real DNS.
  defp resolve(host, _port) do
    resolver = Application.get_env(:quantum_billing, :url_guard_resolver, __MODULE__)
    {:ok, resolver.resolve_with_dns(host)}
  end

  @doc false
  # Every address `host` resolves to, IPv4 and IPv6; `[]` when it resolves to none.
  def resolve_with_dns(host) do
    charlist = String.to_charlist(host)

    v4 = :inet.getaddrs(charlist, :inet, @resolve_timeout_ms)
    v6 = :inet.getaddrs(charlist, :inet6, @resolve_timeout_ms)

    case {v4, v6} do
      {{:ok, a}, {:ok, b}} -> a ++ b
      {{:ok, a}, _} -> a
      {_, {:ok, b}} -> b
      _unresolvable -> []
    end
  end

  # Every resolved address must be public.
  defp check_addresses([]), do: :ok

  defp check_addresses(addresses) do
    if Enum.all?(addresses, &public?/1) do
      :ok
    else
      {:error, "cannot point inside the server's own network"}
    end
  end

  @doc "Whether this server may connect to `address`. Public so the ranges can be tested."
  # Loopback.
  def public?({127, _, _, _}), do: false
  # "This network" — 0.0.0.0/8, which some stacks route to localhost.
  def public?({0, _, _, _}), do: false
  # RFC 1918 private ranges.
  def public?({10, _, _, _}), do: false
  def public?({172, second, _, _}) when second >= 16 and second <= 31, do: false
  def public?({192, 168, _, _}), do: false
  # Link-local, which is where every cloud metadata service lives.
  def public?({169, 254, _, _}), do: false
  # Carrier-grade NAT.
  def public?({100, second, _, _}) when second >= 64 and second <= 127, do: false
  # Multicast and reserved.
  def public?({first, _, _, _}) when first >= 224, do: false
  def public?({_, _, _, _}), do: true

  # IPv6 loopback and unspecified.
  def public?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  def public?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  # IPv4-mapped addresses are judged on the address they map to.
  def public?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    public?(
      {Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)}
    )
  end

  # Unique local addresses, fc00::/7.
  def public?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF, do: false
  # Link-local, fe80::/10.
  def public?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEBF, do: false
  def public?({_, _, _, _, _, _, _, _}), do: true

  def public?(_other), do: false
end
