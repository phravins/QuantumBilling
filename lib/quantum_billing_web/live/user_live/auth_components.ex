defmodule QuantumBillingWeb.UserLive.AuthComponents do
  @moduledoc """
  Presentational pieces for the sign-in / sign-up screens.

  These deliberately use explicit neutral utility classes rather than the
  daisyUI theme tokens the rest of the app uses: the auth design is a
  monochrome, light-only screen (near-black buttons on white), which the
  themed `btn-neutral` / `input` styles do not match.
  """
  use Phoenix.Component

  @input_class "h-10 w-full rounded-md border border-zinc-200 bg-white px-3 text-sm text-zinc-950 " <>
                 "placeholder:text-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-950 " <>
                 "focus:ring-offset-2"

  @primary_button_class "inline-flex h-10 w-full items-center justify-center rounded-md bg-zinc-900 " <>
                          "text-sm font-medium text-white transition-colors hover:bg-zinc-800 " <>
                          "disabled:pointer-events-none disabled:opacity-50"

  @outline_button_class "inline-flex h-10 w-full items-center justify-center rounded-md border " <>
                          "border-zinc-200 bg-white text-sm font-medium text-zinc-950 " <>
                          "transition-colors hover:bg-zinc-100"

  @doc "Shared class list for text inputs on the auth screens."
  def input_class, do: @input_class

  @doc "Shared class list for the primary (near-black) auth button."
  def primary_button_class, do: @primary_button_class

  @doc "Shared class list for outlined auth buttons."
  def outline_button_class, do: @outline_button_class

  @doc """
  Renders a rule with a centered label, e.g. "OR CONTINUE WITH".
  """
  attr :label, :string, default: "Or continue with"

  def or_divider(assigns) do
    ~H"""
    <div class="relative">
      <div class="absolute inset-0 flex items-center">
        <span class="w-full border-t border-zinc-200"></span>
      </div>
      <div class="relative flex justify-center text-xs uppercase">
        <span class="bg-white px-2 text-zinc-500">{@label}</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders the "continue with GitHub" button.

  TODO: this is presentational only. To make it work, add the `ueberauth` and
  `ueberauth_github` dependencies, configure a GitHub OAuth app's client id and
  secret, add the `/auth/github` + `/auth/github/callback` routes, and turn this
  into a link pointing at the request phase.
  """
  attr :rest, :global

  def github_button(assigns) do
    assigns = assign(assigns, :class, @outline_button_class)

    ~H"""
    <button type="button" class={@class} {@rest}>
      <svg viewBox="0 0 16 16" class="mr-2 size-4" fill="currentColor" aria-hidden="true">
        <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
      </svg>
      GitHub
    </button>
    """
  end

  @doc """
  Renders the legal footnote shown under the sign-up form.
  """
  def legal_note(assigns) do
    ~H"""
    <p class="px-8 text-center text-sm text-zinc-500">
      By clicking continue, you agree to our
      <.link href="#" class="underline underline-offset-4 hover:text-zinc-900">
        Terms of Service
      </.link>
      and <.link href="#" class="underline underline-offset-4 hover:text-zinc-900">
        Privacy Policy
      </.link>.
    </p>
    """
  end
end
