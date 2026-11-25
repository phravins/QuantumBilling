defmodule QuantumBillingWeb.DeviceLabel do
  @moduledoc """
  A short, human name for a browser from its user agent, such as
  "Chrome · Windows". Only for showing people; never trusted.
  """

  @doc "The browser and operating system, or \"An unknown browser\"."
  def label(user_agent) when is_binary(user_agent) do
    case {browser(user_agent), os(user_agent)} do
      {nil, nil} -> "An unknown browser"
      {browser, nil} -> browser
      {nil, os} -> "A browser on #{os}"
      {browser, os} -> "#{browser} · #{os}"
    end
  end

  def label(_user_agent), do: "An unknown browser"

  # Order matters: Edge and Opera also say "Chrome", and Chrome also says "Safari".
  defp browser(ua) do
    cond do
      ua =~ "Edg/" -> "Edge"
      ua =~ "OPR/" -> "Opera"
      ua =~ "SamsungBrowser/" -> "Samsung Internet"
      ua =~ "Firefox/" or ua =~ "FxiOS/" -> "Firefox"
      ua =~ "Chrome/" or ua =~ "CriOS/" -> "Chrome"
      ua =~ "Safari/" -> "Safari"
      true -> nil
    end
  end

  defp os(ua) do
    cond do
      ua =~ "Windows" -> "Windows"
      ua =~ "iPhone" or ua =~ "iPad" -> "iOS"
      ua =~ "Android" -> "Android"
      ua =~ "CrOS" -> "ChromeOS"
      ua =~ "Mac OS X" or ua =~ "Macintosh" -> "macOS"
      ua =~ "Linux" -> "Linux"
      true -> nil
    end
  end
end
