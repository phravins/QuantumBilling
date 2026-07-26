defmodule QuantumBillingWeb.ClientsComponents do
  @moduledoc """
  UI building blocks specific to the Clients page.
  """
  use Phoenix.Component

  @palette [
    "bg-violet-500",
    "bg-blue-500",
    "bg-amber-500",
    "bg-teal-500",
    "bg-pink-500",
    "bg-emerald-500",
    "bg-indigo-500",
    "bg-rose-500"
  ]

  @doc """
  Renders a circular initials chip for a client, with a background color
  derived deterministically from the client name.
  """
  attr :name, :string, required: true

  def client_avatar(assigns) do
    assigns =
      assign(assigns,
        initials: initials(assigns.name),
        color: Enum.at(@palette, rem(:erlang.phash2(assigns.name), length(@palette)))
      )

    ~H"""
    <span
      class={[QuantumBillingWeb.SharedComponents.avatar_class(), "shrink-0 text-white", @color]}
      aria-hidden="true"
    >
      {@initials}
    </span>
    """
  end

  # Initials of the first two words; single-word names fall back to their
  # first two characters.
  defp initials(name) do
    case String.split(name, ~r/\s+/, trim: true) do
      [single] -> single |> String.slice(0, 2) |> String.upcase()
      [first, second | _] -> String.upcase(first_char(first) <> first_char(second))
    end
  end

  defp first_char(word), do: String.slice(word, 0, 1)
end
