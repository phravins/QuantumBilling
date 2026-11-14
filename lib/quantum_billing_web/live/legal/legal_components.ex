defmodule QuantumBillingWeb.Legal.LegalComponents do
  @moduledoc """
  Parts for the legal pages. `blank/1` highlights details the operator still has
  to supply, so a leftover one stands out on the page.
  """
  use Phoenix.Component

  @contact_email "phravin@icloud.com"

  @doc "The address for privacy, grievance and legal questions, shared by both documents."
  def contact_email, do: @contact_email

  @doc """
  Renders a numbered document section with a heading and prose body.
  """
  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def legal_section(assigns) do
    ~H"""
    <section id={@id} class="scroll-mt-6 space-y-3">
      <h2 class="text-lg font-semibold text-base-content">{@title}</h2>

      <div class="space-y-3 text-sm leading-relaxed text-base-content/60">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc "Renders a small heading inside a section."
  slot :inner_block, required: true

  def legal_subhead(assigns) do
    ~H"""
    <h3 class="pt-1 text-sm font-semibold text-base-content">{render_slot(@inner_block)}</h3>
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

  @doc "Renders the contact address as a mail link."
  attr :id, :string, required: true

  def legal_email(assigns) do
    assigns = assign(assigns, :email, @contact_email)

    ~H"""
    <a
      id={@id}
      href={"mailto:#{@email}"}
      class="font-medium text-base-content underline underline-offset-4 hover:text-base-content/80"
    >{@email}</a>
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
