defmodule QuantumBilling.Webhooks.UrlGuard do
  @moduledoc """
  Decides whether this server may POST to a URL somebody typed into Settings.

  The webhook endpoint is the one address in this application that a user
  supplies and the *server* then opens a connection to. Validation used to be
  "is it http or https, and does it have a host" — which accepts
  `http://169.254.169.254/latest/meta-data/`, the cloud instance metadata
  service, along with `http://127.0.0.1:5432` and anything else inside the
  network the application is deployed into.

  That is server-side request forgery. The delivery worker discards the
  response body, so it is blind — but a status code still distinguishes an open
  port from a closed one, which is enough to map an internal network, and
  plenty of internal services do something irreversible on a POST.

  ## Checked twice, on purpose

  `check/1` runs when the URL is saved, so a bad one is rejected in the form
  where it can be corrected. It runs again in
  `QuantumBilling.Workers.WebhookDispatchWorker` immediately before the
  request, because DNS is not a constant: a name that resolved to a public
  address at save time can resolve to `127.0.0.1` an hour later, which is the
  whole trick behind DNS rebinding.

  Redirects are refused by the worker rather than followed, since a redirect is
  a second destination this never got to check.

  ## Pinned at send time

  Checking a name and then handing the URL to the HTTP client still leaves a
  gap: the client resolves the name again when it connects, and a DNS server
  that answers with a public address for the check and `127.0.0.1` for the
  connection — a rebinding attack — gets the request inside. So the senders do
  not check and then connect; they call `pin/1`, which resolves once, checks
  every address, and returns the URL rewritten to the address that passed, with
  the original name kept for the `Host` header, TLS SNI and certificate
  verification. The connection then goes exactly where the check looked.
  """

  @doc """
  `:ok` if this server may POST to `url`, `{:error, reason}` otherwise.

  `reason` is a sentence for a form error, not a symbol: the person who typed
  the URL is the one who has to fix it.
  """
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
  Resolves `url` once and fixes the connection to an address that passed.

  Returns `{:ok, pinned_url, req_options}`: the URL with its host replaced by
  the checked address, and the `Req` options that keep the original name for
  the `Host` header, SNI and certificate verification. Pass both to `Req`.

  Stricter than `check/1` about one thing: a name that does not resolve is
  refused here, since there is nothing to pin it to.
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

  # IPv4 first: an address that passed is an address that passed, and IPv4 is
  # the one most hosts actually serve on.
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

  # An unresolvable name is allowed: it cannot be connected to either, and the worker
  # re-checks against live DNS before connecting.
  #
  # The resolver can be swapped by configuration so tests do not depend on the
  # DNS of whatever machine runs them; see `resolve_with_dns/1`.
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

  @doc """
  Whether an address is one this server may open a connection to.

  Public in order to be testable: the list of ranges is the substance of this
  module, and asserting on it through DNS would be asserting on the resolver.
  """
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
