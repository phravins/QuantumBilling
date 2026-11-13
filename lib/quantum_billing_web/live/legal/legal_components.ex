defmodule QuantumBillingWeb.Legal.LegalComponents do
  @moduledoc """
  Parts for the legal pages. `blank/1` highlights unfilled placeholders so they stand out.
  """
  use Phoenix.Component

  @doc """
  Renders a numbered document section with a heading and prose body.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def legal_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-lg font-semibold text-base-content">{@title}</h2>

      <div class="space-y-3 text-sm leading-relaxed text-base-content/60">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  Renders a bulleted list inside a legal section.
  """
  slot :inner_block, required: true

  def legal_list(assigns) do
    ~H"""
    <ul class="list-disc space-y-1 pl-5">
      {render_slot(@inner_block)}
    </ul>
    """
  end

  @doc """
  Renders a highlighted placeholder for a detail that still has to be supplied,
  e.g. `<.blank>registered company name</.blank>`.
  """
  slot :inner_block, required: true

  def blank(assigns) do
    ~H"""
    <span class="rounded bg-amber-100 px-1 font-medium text-amber-900 dark:bg-amber-800 dark:text-amber-100">[{render_slot(
      @inner_block
    )}]</span>
    """
  end
end
