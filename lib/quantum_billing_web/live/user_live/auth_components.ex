defmodule QuantumBillingWeb.UserLive.AuthComponents do
  @moduledoc """
  Presentational pieces specific to the sign-in / sign-up screens.
  """
  use Phoenix.Component

  @doc """
  Renders a horizontal rule with centered label, e.g. "OR CONTINUE WITH".
  """
  attr :label, :string, default: "OR CONTINUE WITH"

  def or_divider(assigns) do
    ~H"""
    <div class="flex items-center gap-3 py-2">
      <span class="h-px flex-1 bg-base-300"></span>
      <span class="text-xs tracking-wide text-base-content/50">{@label}</span>
      <span class="h-px flex-1 bg-base-300"></span>
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
    ~H"""
    <button
      type="button"
      class="btn btn-outline w-full gap-2 border-base-300 font-medium"
      {@rest}
    >
      <svg viewBox="0 0 16 16" class="size-4" fill="currentColor" aria-hidden="true">
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
    <p class="text-center text-sm text-base-content/60">
      By clicking continue, you agree to our
      <.link href="#" class="underline underline-offset-2">Terms of Service</.link>
      and <.link href="#" class="underline underline-offset-2">Privacy Policy</.link>.
    </p>
    """
  end
end
