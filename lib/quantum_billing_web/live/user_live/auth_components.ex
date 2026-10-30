defmodule QuantumBillingWeb.UserLive.AuthComponents do
  @moduledoc """
  Presentational pieces for the sign-in / sign-up screens.

  These use the same theme tokens as the rest of the app. They used to carry
  their own `zinc-*` palette and `rounded-md` corners, which meant the sign-in
  screen quietly drifted from the product it signs you in to — a type-scale or
  radius change would land everywhere except the first screen anyone sees.

  The look is unchanged: the app's light theme is already near-black on white,
  so the theme tokens resolve to what these were hardcoding.
  """
  use Phoenix.Component
  use QuantumBillingWeb, :verified_routes

  @input_class "h-8 w-full rounded-field border border-base-300 bg-base-100 px-3 text-sm " <>
                 "text-base-content placeholder:text-base-content/45 transition-colors " <>
                 "focus:outline-none focus:border-base-content/30 focus:ring-2 " <>
                 "focus:ring-base-content/10"

  @primary_button_class "inline-flex h-8 w-full items-center justify-center rounded-field " <>
                          "bg-primary text-sm font-medium text-primary-content " <>
                          "transition-colors hover:bg-primary/90 " <>
                          "disabled:pointer-events-none disabled:opacity-50"

  @outline_button_class "inline-flex h-8 w-full items-center justify-center rounded-field " <>
                          "border border-base-300 bg-base-100 text-sm font-medium " <>
                          "text-base-content transition-colors hover:bg-base-200"

  @doc "Shared class list for text inputs on the auth screens."
  def input_class, do: @input_class

  @doc "Shared class list for the primary (near-black) auth button."
  def primary_button_class, do: @primary_button_class

  @doc "Shared class list for outlined auth buttons."
  def outline_button_class, do: @outline_button_class

  @doc """
  Renders the legal footnote shown under the sign-up form.
  """
  def legal_note(assigns) do
    ~H"""
    <p class="px-8 text-center text-sm text-base-content/60">
      By clicking continue, you agree to our
      <.link navigate={~p"/terms"} class="underline underline-offset-4 hover:text-base-content">
        Terms of Service
      </.link>
      and <.link navigate={~p"/privacy"} class="underline underline-offset-4 hover:text-base-content">
        Privacy Policy
      </.link>.
    </p>
    """
  end
end
