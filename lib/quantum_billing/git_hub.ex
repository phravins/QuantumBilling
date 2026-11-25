defmodule QuantumBilling.GitHub do
  @moduledoc """
  Reads the project's public GitHub data: the contributors shown on the
  Community page and the latest release shown in the Admin Panel.

  Results are cached for six hours, so a page load costs at most one round of
  requests and the anonymous rate limit is never a concern. Avatars are
  downloaded here and returned as `data:` URIs, so the page's CSP stays
  `img-src 'self' data:` and viewers' browsers never contact GitHub.

  Every call fails soft: on any error the caller gets `{:error, reason}` and
  shows a fallback.
  """

  require Logger

  @repo "phravins/QuantumBilling"
  @api "https://api.github.com"
  @ttl_ms :timer.hours(6)
  @max_contributors 60
  @avatar_px 80
  # Larger avatars are dropped rather than inlined into the page.
  @max_avatar_bytes 40_000

  @doc "The repository's web address."
  def repo_url, do: "https://github.com/#{@repo}"

  @doc """
  The contributors, most commits first, as maps with `:login`, `:profile_url`,
  `:contributions` and `:avatar` (a `data:` URI, or `nil` when it could not be
  fetched).
  """
  def contributors do
    cached(:contributors, fn ->
      with {:ok, list} <- get_json("/repos/#{@repo}/contributors?per_page=#{@max_contributors}") do
        people =
          list
          |> Enum.filter(&(is_map(&1) and &1["type"] == "User" and is_binary(&1["login"])))
          |> Enum.take(@max_contributors)
          |> Task.async_stream(&contributor/1,
            max_concurrency: 8,
            timeout: 10_000,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, person} -> [person]
            {:exit, _reason} -> []
          end)

        {:ok, people}
      end
    end)
  end

  @doc "The latest published release's tag, such as `\"v0.2.0\"`."
  def latest_release do
    cached(:latest_release, fn ->
      case get_json("/repos/#{@repo}/releases/latest") do
        {:ok, %{"tag_name" => tag}} when is_binary(tag) -> {:ok, tag}
        {:ok, _other} -> {:error, :no_release}
        error -> error
      end
    end)
  end

  defp contributor(%{"login" => login} = entry) do
    %{
      login: login,
      profile_url: "https://github.com/#{URI.encode(login)}",
      contributions: entry["contributions"] || 0,
      avatar: avatar(entry["avatar_url"])
    }
  end

  defp avatar(url) when is_binary(url) do
    with %URI{scheme: "https", host: "avatars.githubusercontent.com"} <- URI.parse(url),
         {:ok, %Req.Response{status: 200, body: body} = resp} when is_binary(body) <-
           Req.get(req(), url: url, params: [s: @avatar_px]),
         true <- byte_size(body) <= @max_avatar_bytes,
         type when type in ["image/png", "image/jpeg", "image/gif", "image/webp"] <-
           content_type(resp) do
      "data:#{type};base64," <> Base.encode64(body)
    else
      _ -> nil
    end
  end

  defp avatar(_url), do: nil

  defp content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [type | _] -> type |> String.split(";") |> hd() |> String.trim()
      [] -> nil
    end
  end

  defp get_json(path) do
    case Req.get(req(), url: @api <> path, headers: [accept: "application/vnd.github+json"]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.info("[GitHub] #{path} answered #{status}")
        {:error, {:status, status}}

      {:error, error} ->
        Logger.info("[GitHub] #{path} failed: #{Exception.message(error)}")
        {:error, :unreachable}
    end
  end

  defp req do
    [
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false,
      user_agent: "QuantumBilling"
    ]
    |> Keyword.merge(Application.get_env(:quantum_billing, :github_req_options, []))
    |> Req.new()
  end

  # Errors are not cached, so the next page load tries again.
  defp cached(key, fun) do
    if Application.get_env(:quantum_billing, :github_cache, true) do
      now = System.monotonic_time(:millisecond)

      case :persistent_term.get({__MODULE__, key}, nil) do
        {at, value} when now - at < @ttl_ms ->
          {:ok, value}

        _stale_or_missing ->
          with {:ok, value} <- fun.() do
            :persistent_term.put({__MODULE__, key}, {now, value})
            {:ok, value}
          end
      end
    else
      fun.()
    end
  end
end
