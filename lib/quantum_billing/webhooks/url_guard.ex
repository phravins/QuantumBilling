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
  """

  require Logger

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

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, "must be a full http:// or https:// URL"}
    end
  end

  defp check_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_scheme), do: {:error, "must be a full http:// or https:// URL"}

  defp check_host(host) when is_binary(host) and host != "" do
    # Names that only resolve inside a private network. These usually fail to
    # resolve here anyway, but saying so plainly beats a DNS error.
    if String.ends_with?(host, [".internal", ".local", ".localdomain"]) or
         host in ["localhost", "metadata.google.internal"] do
      {:error, "cannot point inside the server's own network"}
    else
      :ok
    end
  end

  defp check_host(_host), do: {:error, "must include a hostname"}

  # A short timeout: this runs inside a form submit, and a resolver that is not
  # answering should not hold the save open.
  @resolve_timeout_ms 2_000

  # A name that does not resolve is allowed through rather than refused.
  #
  # Failing to resolve is not evidence of pointing somewhere private — it is
  # usually DNS that has not been set up yet, or a resolver this host cannot
  # reach. Refusing it would block legitimate endpoints while protecting
  # nothing: an unresolvable name cannot be connected to either, so the
  # delivery simply fails on its own and retries.
  #
  # Nothing is lost by allowing it. A literal private address
  # (`169.254.169.254`, `127.0.0.1`) needs no DNS and is caught above, and the
  # case that does need DNS — a hostname pointing at a private address — is
  # caught by the worker's check, which resolves against live DNS immediately
  # before it connects.
  defp resolve(host, _port) do
    charlist = String.to_charlist(host)

    v4 = :inet.getaddrs(charlist, :inet, @resolve_timeout_ms)
    v6 = :inet.getaddrs(charlist, :inet6, @resolve_timeout_ms)

    case {v4, v6} do
      {{:ok, a}, {:ok, b}} -> {:ok, a ++ b}
      {{:ok, a}, _} -> {:ok, a}
      {_, {:ok, b}} -> {:ok, b}
      _unresolvable -> {:ok, []}
    end
  end

  # Every address the name resolves to has to be acceptable. A name with one
  # public and one private address is a name that can send this request
  # somewhere it should not go.
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
  # IPv4-mapped (::ffff:a.b.c.d) — judged on the address it maps to, or the
  # whole guard is one `::ffff:` prefix away from being bypassed.
  def public?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    public?({Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)})
  end

  # Unique local addresses, fc00::/7.
  def public?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF, do: false
  # Link-local, fe80::/10.
  def public?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEBF, do: false
  def public?({_, _, _, _, _, _, _, _}), do: true

  def public?(_other), do: false
end
