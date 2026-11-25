defmodule QuantumBillingWeb.MaintenanceHTML do
  @moduledoc "The maintenance page for `MaintenanceController`."
  use QuantumBillingWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div id="maintenance" class="text-center">
        <span class="mx-auto flex size-12 items-center justify-center rounded-full bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300">
          <.icon name="hero-wrench-screwdriver" class="size-6" />
        </span>
        <h1 class="mt-5 text-2xl font-semibold tracking-tight">Down for maintenance</h1>
        <p class="mt-2 text-sm text-base-content/60">
          QuantumBilling is being updated. Your data is safe. Please try again in a few minutes.
        </p>
        <div class="mt-6 flex items-center justify-center gap-2">
          <.link
            href={~p"/"}
            class="inline-flex h-9 items-center rounded-field border border-base-300 px-4 text-sm font-medium transition-colors hover:bg-base-200"
          >
            Try again
          </.link>
          <.link
            :if={@admin?}
            navigate={~p"/admin/health"}
            class="inline-flex h-9 items-center rounded-field bg-primary px-4 text-sm font-medium text-primary-content transition-opacity hover:opacity-90"
          >
            Admin panel
          </.link>
        </div>
      </div>
    </Layouts.auth>
    """
  end
end
